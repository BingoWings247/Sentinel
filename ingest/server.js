// Sentinel ingest — wire protocol v1
// Local:       node ingest/server.js            (no DATABASE_URL = in-memory dev mode)
// Production:  DigitalOcean App Platform, Postgres via DATABASE_URL (see README)

const express = require('express');
const path = require('path');
const { z } = require('zod');
const { analyze } = require('../core/econ-anomaly');
const { normalizeSource } = require('../core/provenance');
const { diagnose } = require('../core/hitch-diagnosis');
const { loadConfig } = require('./config');
const { bearerToken, portalAuth } = require('./auth');
const { scanForSecrets } = require('./privacy');

const CONFIG = loadConfig();

// ---- Wire protocol v1 schemas -------------------------------------------
const EventSchema = z.object({
  id: z.string().min(10),
  t: z.number().int().positive(),
  type: z.string().regex(/^[a-z]+\.[a-z_]+$/),
  src: z.string().min(1),
  data: z.record(z.string(), z.any()),
});

const BatchSchema = z.object({
  v: z.literal(1),
  server_id: z.string().startsWith('srv_'),
  seq: z.number().int().nonnegative(),
  sent_at: z.number().int().positive(),
  agent: z.object({
    version: z.string(),
    artifact: z.string().optional(),
    resource_count: z.number().int().optional(),
    uptime_s: z.number().int().optional(),
  }),
  events: z.array(EventSchema).max(CONFIG.maxEvents),
});

// ---- Storage ----------------------------------------------------------------
// Postgres is the durable copy. `store` below is a bounded in-memory cache of
// the most recent data, which the portal endpoints and detection read from.
function openDatabase() {
  if (CONFIG.databaseUrl) {
    const { createPostgresStore } = require('./db-postgres');
    return createPostgresStore({ databaseUrl: CONFIG.databaseUrl, caCert: CONFIG.databaseCaCert });
  }
  if (CONFIG.isProd) {
    console.error('[sentinel-ingest] BOOT FAILED: DATABASE_URL is not set.');
    console.error('  In production Sentinel stores everything in Postgres and will not run without it.');
    console.error('  On DigitalOcean: App > Settings > the web service > Environment Variables,');
    console.error('  set DATABASE_URL to ${<your-db-component>.DATABASE_URL} and DATABASE_CA_CERT to ${<your-db-component>.CA_CERT}.');
    process.exit(1);
  }
  const { createMemoryStore } = require('./db-memory');
  return createMemoryStore({ devToken: CONFIG.devToken });
}

const db = openDatabase();

const store = {
  events: [],
  lastSeq: new Map(),
  lastBatchAt: null,
  findings: [],
  alerts: [],
};

// ---- Discord notifier (generic: works for any finding type) --------------
async function notifyDiscord(f) {
  if (!CONFIG.discordWebhook) return;
  try {
    const res = await fetch(CONFIG.discordWebhook, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: 'Sentinel',
        embeds: [{
          title: `${f.confidence} — ${f.type === 'econ.anomaly' ? 'Economy Anomaly' : 'Hitch Issue'}`,
          description: f.summary,
          color: f.confidence === 'HIGH' ? 0xFF5C5C : 0xFFB84D,
          fields: [
            f.player && { name: 'Player', value: f.player, inline: true },
            f.amount != null && { name: 'Amount', value: `$${f.amount.toLocaleString()}`, inline: true },
            f.txn_count != null && { name: 'Transactions', value: String(f.txn_count), inline: true },
            f.unsourced_ratio != null && { name: 'Unsourced', value: `${Math.round(f.unsourced_ratio * 100)}%`, inline: true },
            f.count != null && { name: 'Hitches', value: String(f.count), inline: true },
            f.worst_ms != null && { name: 'Worst', value: `${f.worst_ms} ms`, inline: true },
          ].filter(Boolean),
          footer: { text: 'Sentinel · BlackStone Development' },
          timestamp: new Date(f.detected_at).toISOString(),
        }],
      }),
    });
    if (!res.ok) console.error(`[notify] Discord webhook HTTP ${res.status}`);
    return res.ok;
  } catch (err) {
    console.error(`[notify] Discord webhook failed: ${err.message}`);
    return false;
  }
}

// ---- Alert rules (runtime-editable from the portal, saved to the database) --
const RULES = {
  econ_anomaly:     { enabled: true, min_confidence: 'HIGH' },
  perf_hitch_issue: { enabled: true, min_confidence: 'HIGH' },
};
const RANK = { LOW: 1, MED: 2, HIGH: 3 };

function applyRules(saved) {
  if (!saved || typeof saved !== 'object') return;
  for (const key of Object.keys(RULES)) {
    const r = saved[key];
    if (!r) continue;
    if (typeof r.enabled === 'boolean') RULES[key].enabled = r.enabled;
    if (['LOW', 'MED', 'HIGH'].includes(r.min_confidence)) RULES[key].min_confidence = r.min_confidence;
  }
}

async function fireAlert(serverId, f) {
  const key = f.type === 'econ.anomaly' ? 'econ_anomaly' : 'perf_hitch_issue';
  const rule = RULES[key] || { enabled: false, min_confidence: 'HIGH' };
  const record = { at: Date.now(), type: f.type, confidence: f.confidence, summary: f.summary, key: f.key, status: 'muted' };

  if (!rule.enabled) record.status = 'muted';
  else if (RANK[f.confidence] < RANK[rule.min_confidence]) record.status = 'below_threshold';
  else if (!CONFIG.discordWebhook) record.status = 'no_webhook';
  else record.status = (await notifyDiscord(f)) ? 'delivered' : 'failed';

  store.alerts.unshift(record);
  if (store.alerts.length > 200) store.alerts.length = 200;
  console.log(`[alert] ${record.status.toUpperCase()} — ${f.confidence} ${f.type}`);
  db.saveAlert(serverId, record).catch((err) =>
    console.error(`[alert] could not save the alert record to the database: ${err.message}`));
}

// ---- Detection: runs on one server's recent events after each batch ------
async function runDetection(serverId) {
  const recent = store.events.filter((e) => e.server_id === serverId).slice(-CONFIG.detectionWindow);

  // Time windows are measured on the game server's own clock, anchored to its
  // newest event, so a server whose clock runs a little fast or slow is still
  // judged correctly (wire protocol: never trust agent clocks across servers).
  let serverNow = 0;
  for (const e of recent) if (e.t > serverNow) serverNow = e.t;

  // Pass 1: economy anomalies. A key is reported once, ever.
  for (const f of analyze(recent, { now: serverNow || Date.now() })) {
    const { inserted } = await db.saveFinding(serverId, f, { refresh: false });
    if (!inserted) continue;
    store.findings.unshift({ ...f, server_id: serverId });
    console.log(`[core] FINDING ${f.confidence}: ${f.summary}`);
    fireAlert(serverId, f);
  }

  // Pass 2: hitch diagnosis. Grouped issues update in place; alert on first sighting.
  for (const f of diagnose(recent, {})) {
    const { inserted } = await db.saveFinding(serverId, f, { refresh: true });
    const row = { ...f, server_id: serverId };
    const idx = store.findings.findIndex((x) => x.key === f.key && x.server_id === serverId);
    if (idx >= 0) store.findings[idx] = row;
    else store.findings.unshift(row);
    if (inserted) {
      console.log(`[core] FINDING ${f.confidence}: ${f.summary}`);
      fireAlert(serverId, f);
    }
  }

  if (store.findings.length > 500) store.findings.length = 500;
}

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));

// ---- GET /healthz — open, for the platform's health check -----------------
// Always 200 while the process is up, so a brief database failover doesn't
// trigger a restart loop. The database state is reported in the body.
app.get('/healthz', async (req, res) => {
  let database = 'ok';
  try { await db.ping(); } catch { database = 'unreachable'; }
  res.json({ ok: true, store: db.mode, database });
});

// ---- POST /v1/ingest — agents only, bearer token ---------------------------
app.post('/v1/ingest', async (req, res) => {
  const auth = await db.authenticate(bearerToken(req));
  if (!auth.ok) {
    return res.status(401).json({ ok: false, error: { code: 'auth_failed' } });
  }
  const server = auth.server;

  // Validate against the spec — specific, machine-readable rejection (Rule 4/5)
  const parsed = BatchSchema.safeParse(req.body);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return res.status(400).json({
      ok: false,
      error: {
        code: 'invalid_envelope',
        field: issue.path.join('.'),
        detail: issue.message,
      },
    });
  }
  const batch = parsed.data;

  // A token belongs to exactly one server.
  if (!server.dev && batch.server_id !== server.id) {
    return res.status(403).json({
      ok: false,
      error: { code: 'server_mismatch', field: 'server_id', detail: 'server_id does not belong to this token' },
    });
  }

  // Data contract: no secrets or raw identifiers get stored. Name the pattern, never the value.
  for (let i = 0; i < batch.events.length; i++) {
    const hit = scanForSecrets(batch.events[i].data);
    if (hit) {
      return res.status(400).json({
        ok: false,
        error: { code: 'invalid_event', index: i, field: hit.path, detail: `value matched the ${hit.pattern} pattern` },
      });
    }
  }

  const serverId = server.dev ? batch.server_id : server.id;

  // Seq gap detection — dropped batches are observable, never silent (Rule 5)
  const last = server.last_seq ?? store.lastSeq.get(serverId);
  if (last !== undefined && batch.seq > last + 1) {
    console.warn(
      `[ingest] SEQ GAP for ${serverId}: ${last} -> ${batch.seq} ` +
      `(${batch.seq - last - 1} batch(es) missing)`
    );
  }
  store.lastSeq.set(serverId, batch.seq);

  // Durable write first; the cache only ever holds what the database accepted.
  const { received, deduped, inserted } = await db.recordBatch({ ...server, id: serverId }, batch);
  for (const ev of inserted) store.events.push(ev);
  if (store.events.length > CONFIG.recentEventCap) {
    store.events.splice(0, store.events.length - CONFIG.recentEventCap);
  }
  store.lastBatchAt = Date.now();

  console.log(
    `[ingest] seq=${batch.seq} ${serverId}: ` +
    `received=${received} deduped=${deduped} cached=${store.events.length}`
  );

  // The batch is already saved, so a detection failure is logged, not returned:
  // making the agent retry would change nothing.
  try {
    await runDetection(serverId);
  } catch (err) {
    console.error(`[core] detection pass failed for ${serverId}: ${err.message}`);
  }

  res.json({ ok: true, received, deduped, commands: [] });
});

// ---- GET /v1/whoami — an agent learns its own server_id from its token ------
// This is what lets setup be one line in server.cfg: the token alone.
app.get('/v1/whoami', async (req, res) => {
  const auth = await db.authenticate(bearerToken(req));
  if (!auth.ok) {
    return res.status(401).json({ ok: false, error: { code: 'auth_failed' } });
  }
  const s = auth.server;
  res.json({
    ok: true,
    protocol: 1,
    server_id: s.dev ? 'srv_DEV_LOCAL' : s.id,
    name: s.name,
  });
});

// ---- Everything below needs the portal login ------------------------------
app.use(portalAuth({ user: CONFIG.portalUser, password: CONFIG.portalPassword }));

// ---- Portal static hosting ----------------------------------------------
app.use(express.static(path.join(__dirname, '..', 'portal')));

// ---- GET /v1/overview — what the glass reads -----------------------------
app.get('/v1/overview', (req, res) => {
  const now = Date.now();
  const events = store.events;
  const hitches = events.filter(e => e.type === 'server.hitch');
  const joins = events.filter(e => e.type === 'player.join').length;
  const drops = events.filter(e => e.type === 'player.drop').length;
  const econ = events.filter(e => e.type === 'econ.txn');

  const resmon = {};
  for (const e of events.filter(e => e.type === 'perf.resmon')) {
    const r = e.data.resource; if (!r) continue;
    resmon[r] ??= { sum: 0, n: 0, peak: 0 };
    resmon[r].sum += e.data.avg_ms || 0;
    resmon[r].n++;
    resmon[r].peak = Math.max(resmon[r].peak, e.data.peak_ms || 0);
  }

  res.json({
    ok: true,
    generated_at: now,
    last_batch_ago_s: store.lastBatchAt ? Math.round((now - store.lastBatchAt) / 1000) : null,
    total_events: events.length,
    players_online: Math.max(0, joins - drops),
    hitches_today: hitches.length,
    worst_hitch_ms: hitches.reduce((m, e) => Math.max(m, e.data.ms || 0), 0),
    econ_txns: econ.length,
    econ_volume: econ.reduce((s, e) => s + (e.data.amount || 0), 0),
    resources: Object.entries(resmon)
      .map(([name, v]) => ({ name, avg_ms: +(v.sum / v.n).toFixed(2), peak_ms: +v.peak.toFixed(1) }))
      .sort((a, b) => b.avg_ms - a.avg_ms)
      .slice(0, 6),
    recent: events.slice(-8).reverse(),
  });
});

// ---- GET /v1/events — the flight recorder feed ---------------------------
app.get('/v1/events', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit, 10) || 100, 500);
  const type = req.query.type;
  let out = store.events;
  if (type) out = out.filter(e => e.type === type || e.type.startsWith(type + '.'));
  res.json({ ok: true, total: out.length, events: out.slice(-limit).reverse() });
});

// ---- GET /v1/findings ----------------------------------------------------
app.get('/v1/findings', (req, res) => {
  res.json({ ok: true, total: store.findings.length, findings: store.findings.slice(0, 50) });
});

// ---- GET /v1/players — roster aggregation --------------------------------
app.get('/v1/players', (req, res) => {
  const players = new Map();
  for (const e of store.events) {
    const p = e.data?.player;
    if (!p) continue;
    if (!players.has(p)) players.set(p, { name: p, events: 0, joins: 0, drops: 0, econ_in: 0, econ_out: 0, last_seen: 0 });
    const rec = players.get(p);
    rec.events++;
    rec.last_seen = Math.max(rec.last_seen, e.t);
    if (e.type === 'player.join') rec.joins++;
    if (e.type === 'player.drop') rec.drops++;
    if (e.type === 'econ.txn') {
      if (e.data.direction === 'in') rec.econ_in += e.data.amount || 0;
      else rec.econ_out += e.data.amount || 0;
    }
  }
  const findingsByPlayer = new Map();
  for (const f of store.findings) {
    if (!f.player) continue;
    findingsByPlayer.set(f.player, (findingsByPlayer.get(f.player) || 0) + 1);
  }
  const out = [...players.values()]
    .map(p => ({ ...p, findings: findingsByPlayer.get(p.name) || 0 }))
    .sort((a, b) => b.last_seen - a.last_seen);
  res.json({ ok: true, total: out.length, players: out });
});

// ---- GET /v1/player?name= — one player's full picture ---------------------
app.get('/v1/player', (req, res) => {
  const name = req.query.name;
  if (!name) return res.status(400).json({ ok: false, error: { code: 'missing_name' } });
  const events = store.events.filter(e => e.data?.player === name).slice(-100).reverse();
  const findings = store.findings.filter(f => f.player === name);
  res.json({ ok: true, name, events, findings });
});

// ---- GET /v1/staff — accountability trail --------------------------------
app.get('/v1/staff', (req, res) => {
  const actions = store.events.filter(e => e.type === 'staff.action');
  const drops = store.events.filter(e =>
    e.type === 'player.drop' && /ban|kick/i.test(e.data?.reason || ''));

  const byStaffer = new Map();
  for (const e of actions) {
    const s = e.data?.staffer || 'unknown';
    if (!byStaffer.has(s)) byStaffer.set(s, { staffer: s, total: 0, actions: {}, money_given: 0, last_seen: 0 });
    const rec = byStaffer.get(s);
    rec.total++;
    rec.last_seen = Math.max(rec.last_seen, e.t);
    const a = e.data?.action || 'unknown';
    rec.actions[a] = (rec.actions[a] || 0) + 1;
    if (a === 'give_money') {
      const amt = parseInt(String(e.data?.detail || '').replace(/[^0-9]/g, ''), 10) || 0;
      rec.money_given += amt;
    }
  }

  res.json({
    ok: true,
    total: actions.length,
    actions: actions.slice(-150).reverse(),
    drops: drops.slice(-50).reverse(),
    staffers: [...byStaffer.values()].sort((a, b) => b.total - a.total),
  });
});

app.get('/v1/alerts', (req, res) => {
  res.json({
    ok: true,
    webhook_configured: !!CONFIG.discordWebhook,
    rules: RULES,
    alerts: store.alerts.slice(0, 100),
  });
});

app.post('/v1/alerts/rules', async (req, res) => {
  applyRules(req.body || {});
  await db.saveRules(RULES);
  console.log('[alert] rules updated:', JSON.stringify(RULES));
  res.json({ ok: true, rules: RULES });
});

// ---- GET /v1/economy — supply, flows, anomalies ---------------------------
app.get('/v1/economy', (req, res) => {
  const txns = store.events.filter(e => e.type === 'econ.txn');
  let totalIn = 0, totalOut = 0, unsourcedIn = 0;
  const sources = new Map();
  const players = new Map();

  for (const e of txns) {
    const d = e.data || {};
    const amt = d.amount || 0;
    const src = normalizeSource(d.source);   // 'Unknown', '' and missing all mean unknown
    if (!sources.has(src)) sources.set(src, { source: src, in: 0, out: 0, count: 0 });
    const s = sources.get(src);
    s.count++;
    if (d.direction === 'in') { totalIn += amt; s.in += amt; if (src === 'unknown') unsourcedIn += amt; }
    else { totalOut += amt; s.out += amt; }

    const p = d.player;
    if (p) {
      if (!players.has(p)) players.set(p, { player: p, in: 0, out: 0 });
      players.get(p)[d.direction === 'in' ? 'in' : 'out'] += amt;
    }
  }

  // time buckets (12 slices across the observed span)
  const buckets = [];
  if (txns.length) {
    const t0 = txns[0].t, t1 = txns[txns.length - 1].t;
    const span = Math.max(1, t1 - t0), width = span / 12;
    for (let i = 0; i < 12; i++) {
      const from = t0 + i * width;
      const slice = txns.filter(e => e.t >= from && e.t < from + width);
      buckets.push({
        from,
        in: slice.filter(e => e.data.direction === 'in').reduce((s, e) => s + (e.data.amount || 0), 0),
        out: slice.filter(e => e.data.direction !== 'in').reduce((s, e) => s + (e.data.amount || 0), 0),
      });
    }
  }

  res.json({
    ok: true,
    txn_count: txns.length,
    total_in: totalIn,
    total_out: totalOut,
    net: totalIn - totalOut,
    unsourced_in: unsourcedIn,
    unsourced_ratio: totalIn > 0 ? unsourcedIn / totalIn : 0,
    sources: [...sources.values()].sort((a, b) => (b.in + b.out) - (a.in + a.out)).slice(0, 12),
    top_players: [...players.values()].map(p => ({ ...p, net: p.in - p.out }))
      .sort((a, b) => b.net - a.net).slice(0, 10),
    buckets,
    anomalies: store.findings.filter(f => f.type === 'econ.anomaly'),
  });
});

// ---- Errors get a real answer, not an HTML stack trace -----------------------
// (error middleware stays LAST — Express convention)
app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({
      ok: false,
      error: { code: 'invalid_json', detail: err.message },
    });
  }
  if (err.type === 'entity.too.large') {
    return res.status(413).json({
      ok: false,
      error: { code: 'batch_too_large', detail: 'body exceeds 256kb' },
    });
  }
  // Database messages can carry hostnames and values: log them, don't echo them.
  console.error(`[ingest] UNHANDLED on ${req.method} ${req.path}: ${err.message}`);
  res.status(500).json({ ok: false, error: { code: 'internal', detail: 'internal error, see the server log' } });
});

// ---- Retention: raw events older than the data contract allows are deleted --
function scheduleRetention() {
  const run = async () => {
    try {
      const { events } = await db.purge(CONFIG.retentionDays);
      const cutoff = Date.now() - CONFIG.retentionDays * 86_400_000;
      store.events = store.events.filter((e) => e.received_at >= cutoff);
      console.log(`[retention] removed ${events} event(s) older than ${CONFIG.retentionDays} days`);
    } catch (err) {
      console.error(`[retention] purge failed, will retry in 24h: ${err.message}`);
    }
  };
  setTimeout(run, 60_000);
  setInterval(run, 86_400_000);
}

// ---- Boot ------------------------------------------------------------------
async function main() {
  let migrations;
  try {
    migrations = await db.init();
  } catch (err) {
    console.error('[sentinel-ingest] BOOT FAILED: could not prepare the database.');
    console.error(`  ${err.message}`);
    console.error('  Check DATABASE_URL, DATABASE_CA_CERT, and that this app is a Trusted Source on the database.');
    process.exit(1);
  }

  const warm = await db.loadRecent({ events: CONFIG.recentEventCap });
  store.events = warm.events;
  store.findings = warm.findings;
  store.alerts = warm.alerts;
  applyRules(warm.rules);
  if (store.events.length) store.lastBatchAt = store.events[store.events.length - 1].received_at;

  const server = app.listen(CONFIG.port, () => {
    console.log('[sentinel-ingest] BOOT OK');
    console.log(`  port:       ${CONFIG.port}`);
    console.log(`  store:      ${db.describe()}`);
    if (db.mode === 'postgres') {
      console.log(`  migrations: ${migrations.applied.length ? `applied ${migrations.applied.join(', ')}` : `up to date (${migrations.total})`}`);
    }
    console.log(`  restored:   ${store.events.length} events, ${store.findings.length} findings, ${store.alerts.length} alerts`);
    console.log(`  agents:     ${db.mode === 'memory' ? 'dev token only (SENTINEL_DEV_TOKEN)' : 'per-server tokens (npm run server:create)'}`);
    console.log(`  portal:     login required, user "${CONFIG.portalUser}"`);
    if (CONFIG.portalPasswordGenerated) console.log(`  portal pw:  ${CONFIG.portalPassword}   (one-time, set PORTAL_PASSWORD)`);
    console.log(`  retention:  raw events ${CONFIG.retentionDays} days`);
    console.log(`  protocol:   v1 · max ${CONFIG.maxEvents} events/batch · 256kb limit`);
    console.log(`  notify:     ${CONFIG.discordWebhook ? 'Discord webhook configured' : 'no webhook (set SENTINEL_WEBHOOK)'}`);
    for (const f of CONFIG.fallbacks) console.log(`  fallback:   ${f}`);
    for (const w of [...CONFIG.warnings, db.sslWarning].filter(Boolean)) console.warn(`  WARNING:    ${w}`);
    console.log('  waiting on POST /v1/ingest ...');
  });

  scheduleRetention();

  // DigitalOcean sends SIGTERM on every deploy: finish in-flight requests, then close the pool.
  const shutdown = (sig) => {
    console.log(`[sentinel-ingest] ${sig} received, shutting down`);
    server.close(() => db.close().finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  console.error(`[sentinel-ingest] BOOT FAILED: ${err.message}`);
  process.exit(1);
});
