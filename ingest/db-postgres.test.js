// ingest/db-postgres.test.js
// Runs against a real Postgres. Skipped unless TEST_DATABASE_URL is set.
// It creates a throwaway database, runs everything there, and drops it.
//   TEST_DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres npm test
// Never point it at the production database URL: it needs CREATE DATABASE rights.

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { createPostgresStore, buildPoolConfig } = require('./db-postgres');

const ADMIN_URL = process.env.TEST_DATABASE_URL;
const skip = ADMIN_URL ? false : 'TEST_DATABASE_URL not set';

let admin, store, dbName, testUrl;

before(async () => {
  if (skip) return;
  const { Client } = require('pg');
  dbName = `sentinel_test_${crypto.randomBytes(4).toString('hex')}`;
  admin = new Client({ connectionString: ADMIN_URL });
  await admin.connect();
  await admin.query(`CREATE DATABASE ${dbName}`);
  const u = new URL(ADMIN_URL);
  u.pathname = `/${dbName}`;
  testUrl = u.toString();
  store = createPostgresStore({ databaseUrl: testUrl, caCert: '', log: { error() {} } });
});

after(async () => {
  if (skip) return;
  await store.close();
  await admin.query(`DROP DATABASE IF EXISTS ${dbName} WITH (FORCE)`);
  await admin.end();
});

const ev = (id, extra = {}) => ({
  id, t: 1_791_000_000_000 + Number(id.replace(/\D/g, '') || 0), type: 'econ.txn', src: 'bsd_banking',
  data: { player: 'Kaiden_R', direction: 'in', amount: 500, source: 'bsd_banking:deposit', note: 'quote " and \\ backslash' },
  ...extra,
});
const batch = (seq, events) => ({
  v: 1, server_id: 'ignored-here', seq, sent_at: Date.now(), agent: { version: 'test' }, events,
});

test('migrations apply once, then report up to date', { skip }, async () => {
  const first = await store.init();
  assert.deepEqual(first.applied, ['001_init.sql']);
  const second = await store.init();
  assert.deepEqual(second.applied, []);
});

let server, token;

test('server tokens: valid, unknown, revoked', { skip }, async () => {
  const created = await store.createServer('Test RP');
  server = { id: created.id }; token = created.token;
  assert.match(created.id, /^srv_/);
  assert.match(created.token, /^sst_/);

  const ok = await store.authenticate(token);
  assert.equal(ok.ok, true);
  assert.equal(ok.server.id, created.id);
  assert.equal(ok.server.last_seq, undefined);

  assert.deepEqual(await store.authenticate('sst_nope'), { ok: false, reason: 'unknown' });
  assert.deepEqual(await store.authenticate(''), { ok: false, reason: 'missing' });

  const other = await store.createServer('Revoke me');
  assert.equal(await store.revokeServer(other.id), true);
  assert.equal(await store.revokeServer(other.id), false);
  assert.deepEqual(await store.authenticate(other.token), { ok: false, reason: 'revoked' });

  // The token itself is never stored, only its hash and a short hint.
  const { Client } = require('pg');
  const c = new Client({ connectionString: testUrl });
  await c.connect();
  const { rows } = await c.query('SELECT * FROM servers');
  await c.end();
  assert.ok(rows.every((r) => !JSON.stringify(r).includes(token)));
});

test('batches: insert, retry dedupe, in-batch dedupe, last_seq', { skip }, async () => {
  const r1 = await store.recordBatch(server, batch(0, [ev('evt_1'), ev('evt_2'), ev('evt_2')]));
  assert.equal(r1.received, 2);
  assert.equal(r1.deduped, 1);
  assert.deepEqual(r1.inserted.map((e) => e.id), ['evt_1', 'evt_2']);
  assert.equal(r1.inserted[0].server_id, server.id);
  assert.equal(typeof r1.inserted[0].received_at, 'number');

  const r2 = await store.recordBatch(server, batch(1, [ev('evt_2'), ev('evt_3')]));
  assert.equal(r2.received, 1);
  assert.equal(r2.deduped, 1);

  const empty = await store.recordBatch(server, batch(2, [])); // heartbeat
  assert.equal(empty.received, 0);

  const auth = await store.authenticate(token);
  assert.equal(auth.server.last_seq, 2);
});

test('findings: insert-once vs refresh in place', { skip }, async () => {
  const f = { key: 'econ:Kaiden_R:1', type: 'econ.anomaly', confidence: 'HIGH', summary: 's', detected_at: Date.now() };
  assert.equal((await store.saveFinding(server.id, f)).inserted, true);
  assert.equal((await store.saveFinding(server.id, f)).inserted, false);

  const h = { key: 'hitch:oxmysql', type: 'perf.hitch_issue', confidence: 'MED', summary: 'x', count: 1 };
  assert.equal((await store.saveFinding(server.id, h, { refresh: true })).inserted, true);
  assert.equal((await store.saveFinding(server.id, { ...h, count: 7, confidence: 'HIGH' }, { refresh: true })).inserted, false);
});

test('alerts and rules persist; loadRecent restores everything in order', { skip }, async () => {
  await store.saveAlert(server.id, { at: Date.now(), type: 'econ.anomaly', confidence: 'HIGH', summary: 'dupe', key: 'k', status: 'no_webhook' });
  await store.saveRules({ econ_anomaly: { enabled: false, min_confidence: 'MED' } });

  const warm = await store.loadRecent({ events: 100 });
  assert.deepEqual(warm.events.map((e) => e.id), ['evt_1', 'evt_2', 'evt_3']);
  assert.equal(typeof warm.events[0].t, 'number');
  assert.equal(warm.events[0].data.note, 'quote " and \\ backslash');
  assert.equal(warm.events[0].server_id, server.id);

  const hitch = warm.findings.find((x) => x.key === 'hitch:oxmysql');
  assert.equal(hitch.count, 7);
  assert.equal(hitch.confidence, 'HIGH');
  assert.equal(hitch.server_id, server.id);
  assert.equal(warm.findings.length, 2);

  assert.equal(warm.alerts.length, 1);
  assert.equal(warm.alerts[0].status, 'no_webhook');
  assert.equal(typeof warm.alerts[0].at, 'number');
  assert.deepEqual(warm.rules, { econ_anomaly: { enabled: false, min_confidence: 'MED' } });
});

test('retention purge deletes only events older than the window', { skip }, async () => {
  const { Client } = require('pg');
  const c = new Client({ connectionString: testUrl });
  await c.connect();
  await c.query(`UPDATE events SET received_at = now() - interval '31 days' WHERE id = 'evt_1'`);
  await c.end();
  const { events } = await store.purge(30);
  assert.equal(events, 1);
  const warm = await store.loadRecent({ events: 100 });
  assert.deepEqual(warm.events.map((e) => e.id), ['evt_2', 'evt_3']);
});

test('ping works', { skip }, async () => {
  assert.equal(await store.ping(), true);
});

// ---- Connection settings: no database needed --------------------------------
test('SSL: URL sslmode is stripped and a CA turns on verification', () => {
  const ca = '-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----';
  const url = 'postgresql://doadmin:pw@db-x.ondigitalocean.com:25060/defaultdb?sslmode=require';

  const withCa = buildPoolConfig(url, ca);
  assert.ok(!withCa.poolConfig.connectionString.includes('sslmode'));
  assert.deepEqual(withCa.poolConfig.ssl, { ca, rejectUnauthorized: true });
  assert.equal(withCa.sslWarning, null);
  assert.equal(withCa.host, 'db-x.ondigitalocean.com');
  assert.equal(withCa.database, 'defaultdb');

  const noCa = buildPoolConfig(url, '');
  assert.deepEqual(noCa.poolConfig.ssl, { rejectUnauthorized: false });
  assert.match(noCa.sslWarning, /DATABASE_CA_CERT/);

  const local = buildPoolConfig('postgres://postgres@127.0.0.1:5432/sentinel', '');
  assert.equal(local.poolConfig.ssl, false);
});
