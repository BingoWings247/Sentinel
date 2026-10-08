// ingest/db-postgres.js
// Postgres persistence for the ingest server. The server keeps a bounded
// in-memory cache for the portal and detection; this module is the durable
// copy underneath it. Every write here is the source of truth.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Pool } = require('pg');

const MIGRATIONS_DIR = path.join(__dirname, 'migrations');
const MIGRATION_LOCK = 4_771_002; // pg_advisory_lock key: one migrator at a time

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const ms = (d) => (d instanceof Date ? d.getTime() : Number(d));

// ---- Connection settings ----------------------------------------------------
// node-postgres lets sslmode in the URL override an explicit ssl object, and it
// treats sslmode=require as verify-full. DigitalOcean signs its database certs
// with its own CA, so we strip the URL's SSL parameters and decide here.
function buildPoolConfig(databaseUrl, caCert) {
  const url = new URL(databaseUrl);
  const sslmode = (url.searchParams.get('sslmode') || '').toLowerCase();
  for (const p of ['sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'ssl', 'uselibpqcompat']) {
    url.searchParams.delete(p);
  }

  let ssl;
  let sslDescription;
  let sslWarning = null;
  if (caCert) {
    ssl = { ca: caCert, rejectUnauthorized: true };
    sslDescription = 'verified against DATABASE_CA_CERT';
  } else if (sslmode && sslmode !== 'disable') {
    ssl = { rejectUnauthorized: false };
    sslDescription = 'encrypted, certificate NOT verified';
    sslWarning = 'DATABASE_CA_CERT is not set, so the database certificate is not verified. On DigitalOcean, set DATABASE_CA_CERT to ${db.CA_CERT}.';
  } else {
    ssl = false;
    sslDescription = 'off (fine for a local database only)';
  }

  return {
    poolConfig: {
      connectionString: url.toString(),
      ssl,
      max: 5,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 10_000,
    },
    host: url.hostname,
    database: url.pathname.replace(/^\//, ''),
    sslDescription,
    sslWarning,
  };
}

function createPostgresStore({ databaseUrl, caCert, log = console }) {
  const settings = buildPoolConfig(databaseUrl, caCert);
  const pool = new Pool(settings.poolConfig);

  // An idle client dying (database restart, failover) must be loud, not fatal.
  pool.on('error', (err) => log.error(`[db] idle connection error: ${err.message}`));

  async function tx(fn) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const out = await fn(client);
      await client.query('COMMIT');
      return out;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    } finally {
      client.release();
    }
  }

  // ---- Migrations -------------------------------------------------------------
  async function migrate() {
    const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => /^\d+_.+\.sql$/.test(f)).sort();
    const client = await pool.connect();
    const applied = [];
    try {
      await client.query('SELECT pg_advisory_lock($1)', [MIGRATION_LOCK]);
      await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
        version    text        PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now())`);
      const done = new Set((await client.query('SELECT version FROM schema_migrations')).rows.map((r) => r.version));
      for (const file of files) {
        if (done.has(file)) continue;
        const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
        try {
          await client.query('BEGIN');
          await client.query(sql);
          await client.query('INSERT INTO schema_migrations (version) VALUES ($1)', [file]);
          await client.query('COMMIT');
          applied.push(file);
        } catch (err) {
          await client.query('ROLLBACK').catch(() => {});
          throw new Error(`migration ${file} failed: ${err.message}`);
        }
      }
      return { applied, total: files.length };
    } finally {
      await client.query('SELECT pg_advisory_unlock($1)', [MIGRATION_LOCK]).catch(() => {});
      client.release();
    }
  }

  // ---- Reads used to warm the in-memory cache at boot -------------------------
  async function loadRecent({ events: eventLimit, findings: findingLimit = 500, alerts: alertLimit = 200 }) {
    const ev = await pool.query(
      `SELECT server_id, id, t, type, src, data, received_at
         FROM events ORDER BY received_at DESC, id DESC LIMIT $1`, [eventLimit]);
    const fi = await pool.query(
      'SELECT body FROM findings ORDER BY updated_at DESC LIMIT $1', [findingLimit]);
    const al = await pool.query(
      `SELECT at, type, confidence, summary, key, status
         FROM alerts ORDER BY at DESC, id DESC LIMIT $1`, [alertLimit]);
    const rules = await pool.query(`SELECT value FROM settings WHERE key = 'alert_rules'`);

    return {
      events: ev.rows.reverse().map((r) => ({
        id: r.id, t: Number(r.t), type: r.type, src: r.src, data: r.data,
        server_id: r.server_id, received_at: ms(r.received_at),
      })),
      findings: fi.rows.map((r) => r.body),
      alerts: al.rows.map((r) => ({
        at: ms(r.at), type: r.type, confidence: r.confidence,
        summary: r.summary, key: r.key, status: r.status,
      })),
      rules: rules.rows[0]?.value || null,
    };
  }

  // ---- Agent authentication --------------------------------------------------
  async function authenticate(token) {
    if (!token) return { ok: false, reason: 'missing' };
    const { rows } = await pool.query(
      'SELECT id, name, revoked_at, last_seq FROM servers WHERE token_hash = $1', [sha256(token)]);
    const s = rows[0];
    if (!s) return { ok: false, reason: 'unknown' };
    if (s.revoked_at) return { ok: false, reason: 'revoked' };
    return {
      ok: true,
      server: { id: s.id, name: s.name, last_seq: s.last_seq == null ? undefined : Number(s.last_seq) },
    };
  }

  // ---- Batch write: events + server bookkeeping in one transaction -----------
  async function recordBatch(server, batch) {
    const ids = [], ts = [], types = [], srcs = [], datas = [];
    for (const e of batch.events) {
      ids.push(e.id); ts.push(e.t); types.push(e.type); srcs.push(e.src); datas.push(JSON.stringify(e.data));
    }
    return tx(async (c) => {
      let inserted = [];
      if (ids.length) {
        const { rows } = await c.query(
          `INSERT INTO events (server_id, id, t, type, src, data)
           SELECT $1, u.id, u.t, u.type, u.src, u.data
             FROM unnest($2::text[], $3::bigint[], $4::text[], $5::text[], $6::jsonb[])
                  AS u(id, t, type, src, data)
           ON CONFLICT (server_id, id) DO NOTHING
           RETURNING id, received_at`,
          [server.id, ids, ts, types, srcs, datas]);
        const at = new Map(rows.map((r) => [r.id, ms(r.received_at)]));
        // Keep batch order, and only the first copy of an id repeated inside one batch.
        const seen = new Set();
        inserted = batch.events
          .filter((e) => at.has(e.id) && !seen.has(e.id) && seen.add(e.id))
          .map((e) => ({ ...e, server_id: server.id, received_at: at.get(e.id) }));
      }
      await c.query(
        'UPDATE servers SET last_seen_at = now(), last_seq = $2, last_agent = $3 WHERE id = $1',
        [server.id, batch.seq, JSON.stringify(batch.agent)]);
      return { received: inserted.length, deduped: batch.events.length - inserted.length, inserted };
    });
  }

  // ---- Findings, alerts, settings --------------------------------------------
  // refresh=false: first sighting only (economy anomalies).
  // refresh=true: grouped issues that update in place (hitch diagnosis).
  async function saveFinding(serverId, f, { refresh = false } = {}) {
    const body = JSON.stringify({ ...f, server_id: serverId });
    const sql = refresh
      ? `INSERT INTO findings (server_id, key, type, confidence, body) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (server_id, key) DO UPDATE
           SET body = EXCLUDED.body, confidence = EXCLUDED.confidence, updated_at = now()
         RETURNING (xmax = 0) AS inserted`
      : `INSERT INTO findings (server_id, key, type, confidence, body) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (server_id, key) DO NOTHING
         RETURNING true AS inserted`;
    const { rows } = await pool.query(sql, [serverId, f.key, f.type, f.confidence, body]);
    return { inserted: rows[0]?.inserted === true };
  }

  async function saveAlert(serverId, a) {
    await pool.query(
      `INSERT INTO alerts (server_id, at, type, confidence, summary, key, status)
       VALUES ($1, to_timestamp($2 / 1000.0), $3, $4, $5, $6, $7)`,
      [serverId, a.at, a.type, a.confidence, a.summary, a.key || null, a.status]);
  }

  async function saveRules(rules) {
    await pool.query(
      `INSERT INTO settings (key, value) VALUES ('alert_rules', $1)
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
      [JSON.stringify(rules)]);
  }

  async function purge(days) {
    const { rowCount } = await pool.query(
      'DELETE FROM events WHERE received_at < now() - make_interval(days => $1)', [days]);
    return { events: rowCount };
  }

  // ---- Server management (scripts/servers.js) -------------------------------
  async function createServer(name) {
    const token = `sst_${crypto.randomBytes(32).toString('base64url')}`;
    const id = `srv_${Date.now().toString(36).toUpperCase()}${crypto.randomBytes(4).toString('hex').toUpperCase()}`;
    await pool.query(
      'INSERT INTO servers (id, name, token_hash, token_hint) VALUES ($1, $2, $3, $4)',
      [id, name, sha256(token), token.slice(0, 8)]);
    return { id, name, token };
  }

  async function listServers() {
    const { rows } = await pool.query(
      `SELECT id, name, token_hint, created_at, revoked_at, last_seen_at, last_seq
         FROM servers ORDER BY created_at`);
    return rows;
  }

  async function revokeServer(id) {
    const { rowCount } = await pool.query(
      'UPDATE servers SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL', [id]);
    return rowCount === 1;
  }

  return {
    mode: 'postgres',
    describe: () => `postgres ${settings.host}/${settings.database}, TLS ${settings.sslDescription}`,
    sslWarning: settings.sslWarning,
    init: migrate,
    ping: async () => { await pool.query('SELECT 1'); return true; },
    loadRecent, authenticate, recordBatch, saveFinding, saveAlert, saveRules, purge,
    createServer, listServers, revokeServer,
    close: () => pool.end(),
  };
}

module.exports = { createPostgresStore, buildPoolConfig };
