// Sentinel ingest — wire protocol v1 (vertical slice)
// Save as: C:\dev\sentinel\ingest\server.js
// Run:     node ingest/server.js

const express = require('express');
const { z } = require('zod');

const CONFIG = {
  port: 3000,
  devToken: 'dev_token_change_me',
  maxEvents: 500,
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
};

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

  console.log(
    `[ingest] seq=${batch.seq} ${batch.server_id}: ` +
    `received=${received} deduped=${deduped} stored_total=${store.events.length}`
  );

  res.json({ ok: true, received, deduped, commands: [] });
});

// ---- Portal static hosting ----------------------------------------------
const path = require('path');
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

// ---- GET /v1/events — the flight recorder feed ---------------------------
app.get('/v1/events', (req, res) => {
  const limit = Math.min(parseInt(req.query.limit, 10) || 100, 500);
  const type = req.query.type;
  let out = store.events;
  if (type) out = out.filter(e => e.type === type || e.type.startsWith(type + '.'));
  res.json({ ok: true, total: out.length, events: out.slice(-limit).reverse() });
});

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

// ---- Malformed JSON bodies get a real answer, not an HTML stack trace ----
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

// ---- Boot self-report (Rule 1) -------------------------------------------
app.listen(CONFIG.port, () => {
  console.log('[sentinel-ingest] BOOT OK');
  console.log(`  port:     ${CONFIG.port}`);
  console.log(`  auth:     static dev token — replace before anything public`);
  console.log(`  store:    in-memory (volatile, lost on restart)`);
  console.log(`  protocol: v1 · max ${CONFIG.maxEvents} events/batch · 256kb limit`);
  console.log(`  waiting on POST /v1/ingest ...`);
});