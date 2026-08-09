// Sentinel ingest — wire protocol v1 (vertical slice)
// Run: $env:SENTINEL_WEBHOOK="<webhook url>"  then  node ingest/server.js

const express = require('express');
const path = require('path');
const { z } = require('zod');
const { analyze } = require('../core/econ-anomaly');
const { diagnose } = require('../core/hitch-diagnosis');

const CONFIG = {
  port: 3000,
  devToken: 'dev_token_change_me',
  maxEvents: 500,
  discordWebhook: process.env.SENTINEL_WEBHOOK || '', // env only — NEVER paste the URL here
};

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

// ---- In-memory store (slice only — a real DB replaces this later) -------
const store = {
  events: [],
  seenIds: new Set(),
  lastSeq: new Map(),
  lastBatchAt: null,
  findings: [],
  findingKeys: new Set(),
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

// ---- Alert rules (runtime-editable; moves to DB with the rest) -----------
const RULES = {
  econ_anomaly:     { enabled: true, min_confidence: 'HIGH' },
  perf_hitch_issue: { enabled: true, min_confidence: 'HIGH' },
};
const RANK = { LOW: 1, MED: 2, HIGH: 3 };

async function fireAlert(f) {
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
}

const app = express();
app.use(express.json({ limit: '256kb' }));

// ---- POST /v1/ingest -----------------------------------------------------
app.post('/v1/ingest', (req, res) => {
  // Auth (subscription enforcement lives here eventually)
  const auth = req.headers.authorization || '';
  if (auth !== `Bearer ${CONFIG.devToken}`) {
    return res.status(401).json({ ok: false, error: { code: 'auth_failed' } });
  }

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

  // Seq gap detection — dropped batches are observable, never silent (Rule 5)
  const last = store.lastSeq.get(batch.server_id);
  if (last !== undefined && batch.seq > last + 1) {
    console.warn(
      `[ingest] SEQ GAP for ${batch.server_id}: ${last} -> ${batch.seq} ` +
      `(${batch.seq - last - 1} batch(es) missing)`
    );
  }
  store.lastSeq.set(batch.server_id, batch.seq);

  // Dedupe on event id — retries are free
  let received = 0;
  let deduped = 0;
  for (const ev of batch.events) {
    if (store.seenIds.has(ev.id)) { deduped++; continue; }
    store.seenIds.add(ev.id);
    store.events.push({ ...ev, server_id: batch.server_id, received_at: Date.now() });
    received++;
  }
  store.lastBatchAt = Date.now();

  // Ring-buffer the slice store: cap memory, keep dedupe honest
  if (store.events.length > 20000) {
    const removed = store.events.splice(0, store.events.length - 20000);
    for (const ev of removed) store.seenIds.delete(ev.id);
  }

  console.log(
    `[ingest] seq=${batch.seq} ${batch.server_id}: ` +
    `received=${received} deduped=${deduped} stored_total=${store.events.length}`
  );

  // ---- Detection pass 1: economy anomalies -------------------------------
   const recentEvents = store.events.slice(-4000);
   const newFindings = analyze(recentEvents, {});
  for (const f of newFindings) {
    if (store.findingKeys.has(f.key)) continue;
    store.findingKeys.add(f.key);
    store.findings.unshift(f);
    console.log(`[core] FINDING ${f.confidence}: ${f.summary}`);
    fireAlert(f);
  }

  // ---- Detection pass 2: hitch diagnosis (grouped issues update in place) -
   const hitchIssues = diagnose(recentEvents, {});
  for (const f of hitchIssues) {
    const idx = store.findings.findIndex((x) => x.key === f.key);
    if (idx >= 0) {
      store.findings[idx] = f; // refresh count / last_seen / worst
    } else {
      store.findings.unshift(f);
      console.log(`[core] FINDING ${f.confidence}: ${f.summary}`);
      fireAlert(f);
    }
  }

  res.json({ ok: true, received, deduped, commands: [] });
});

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

// ---- Malformed JSON bodies get a real answer, not an HTML stack trace ----
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
  console.error('[ingest] UNHANDLED:', err);
  res.status(500).json({ ok: false, error: { code: 'internal', detail: err.message } });
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

app.post('/v1/alerts/rules', (req, res) => {
  const body = req.body || {};
  for (const key of Object.keys(RULES)) {
    if (!body[key]) continue;
    if (typeof body[key].enabled === 'boolean') RULES[key].enabled = body[key].enabled;
    if (['LOW','MED','HIGH'].includes(body[key].min_confidence)) RULES[key].min_confidence = body[key].min_confidence;
  }
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
    const src = d.source || 'unknown';
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

// ---- Boot self-report (Rule 1) -------------------------------------------
app.listen(CONFIG.port, () => {
  console.log('[sentinel-ingest] BOOT OK');
  console.log(`  port:     ${CONFIG.port}`);
  console.log(`  auth:     static dev token — replace before anything public`);
  console.log(`  store:    in-memory (volatile, lost on restart)`);
  console.log(`  protocol: v1 · max ${CONFIG.maxEvents} events/batch · 256kb limit`);
  console.log(`  notify:   ${CONFIG.discordWebhook ? 'Discord webhook configured' : 'no webhook (set SENTINEL_WEBHOOK)'}`);
  console.log(`  waiting on POST /v1/ingest ...`);
});