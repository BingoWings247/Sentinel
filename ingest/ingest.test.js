// ingest/ingest.test.js — pure tests for config, auth and the privacy gate.
// No database, no network:  node --test "ingest/*.test.js"

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('./config');
const { bearerToken, portalAuth, safeEqual } = require('./auth');
const { scanForSecrets } = require('./privacy');

// ---- config ------------------------------------------------------------------
test('config: defaults are used and reported', () => {
  const c = loadConfig({});
  assert.equal(c.port, 3000);
  assert.equal(c.portalUser, 'admin');
  assert.equal(c.portalPasswordGenerated, true);
  assert.ok(c.portalPassword.length >= 20);
  assert.equal(c.retentionDays, 30);
  assert.ok(c.fallbacks.some((f) => f.includes('PORTAL_USER')));
  assert.ok(c.warnings.some((w) => w.includes('PORTAL_PASSWORD')));
});

test('config: bad values fall back, retention is capped at the contract', () => {
  const c = loadConfig({ PORT: 'abc', RETENTION_EVENT_DAYS: '90', PORTAL_PASSWORD: 'short' });
  assert.equal(c.port, 3000);
  assert.equal(c.retentionDays, 30);
  assert.ok(c.fallbacks.some((f) => f.includes('capped')));
  assert.ok(c.warnings.some((w) => w.includes('shorter than 16')));
});

test('config: a CA with literal \\n is normalised', () => {
  const c = loadConfig({ DATABASE_CA_CERT: '-----BEGIN-----\\nabc\\n-----END-----' });
  assert.equal(c.databaseCaCert, '-----BEGIN-----\nabc\n-----END-----');
});

// ---- auth --------------------------------------------------------------------
test('bearer token is read from the header only', () => {
  assert.equal(bearerToken({ headers: { authorization: 'Bearer sst_abc' } }), 'sst_abc');
  assert.equal(bearerToken({ headers: { authorization: 'Basic xyz' } }), '');
  assert.equal(bearerToken({ headers: {} }), '');
});

test('safeEqual', () => {
  assert.equal(safeEqual('a', 'a'), true);
  assert.equal(safeEqual('a', 'b'), false);
  assert.equal(safeEqual('a', 'aa'), false);
});

function runAuth(header) {
  const mw = portalAuth({ user: 'admin', password: 'correct horse battery' });
  const res = {
    statusCode: 200, headers: {}, body: null,
    set(k, v) { this.headers[k] = v; return this; },
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  };
  let passed = false;
  mw({ headers: header ? { authorization: header } : {} }, res, () => { passed = true; });
  return { passed, res };
}
const basic = (u, p) => `Basic ${Buffer.from(`${u}:${p}`).toString('base64')}`;

test('portal login: right credentials pass, everything else gets 401 + challenge', () => {
  assert.equal(runAuth(basic('admin', 'correct horse battery')).passed, true);
  for (const h of [null, basic('admin', 'wrong'), basic('root', 'correct horse battery'), 'Bearer sst_x', 'Basic !!!']) {
    const { passed, res } = runAuth(h);
    assert.equal(passed, false);
    assert.equal(res.statusCode, 401);
    assert.match(res.headers['WWW-Authenticate'], /^Basic realm="Sentinel"/);
  }
});

test('portal login: a password containing ":" still works', () => {
  const mw = portalAuth({ user: 'admin', password: 'a:b:c' });
  let passed = false;
  mw({ headers: { authorization: basic('admin', 'a:b:c') } }, { set() { return this; }, status() { return this; }, json() {} }, () => { passed = true; });
  assert.equal(passed, true);
});

// ---- privacy gate ------------------------------------------------------------
test('privacy: clean wire-protocol data passes', () => {
  assert.equal(scanForSecrets({ player: 'Kaiden_R', player_id: 'a'.repeat(32), amount: 500, source: 'bsd_banking:deposit' }), null);
  assert.equal(scanForSecrets({ reason: 'Banned: mod menu (txAdmin)', session_s: 300 }), null);
});

test('privacy: raw identifiers and secrets are caught, by name and path, never value', () => {
  const lic = scanForSecrets({ player: 'x', license: 'license:abc123def456' });
  assert.deepEqual(lic, { path: 'data.license', pattern: 'identifier' });

  const hook = scanForSecrets({ detail: 'see https://discord.com/api/webhooks/123/abcDEF_ghi' });
  assert.equal(hook.pattern, 'discord_webhook');

  const nested = scanForSecrets({ staffer: { name: 'Mod', notes: ['ok', 'mysql://root:pw@db/rp'] } });
  assert.deepEqual(nested, { path: 'data.staffer.notes.1', pattern: 'db_uri' });

  const pair = scanForSecrets({ password: 'hunter2hunter2' });
  assert.equal(pair.path, 'data.password');
  assert.equal(pair.pattern, 'generic_assignment');
});
