// core/finding.test.js
// Run from project root:  node --test core/

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { validateFinding, normalizeLegacy, assertNoSecrets } = require('./finding');
const { analyze } = require('./econ-anomaly');
const { diagnose } = require('./hitch-diagnosis');

const NOW = 1_753_400_000_000;
let n = 0;
const evt = (type, t, data, src = 'server') => ({ id: `evt_test_${++n}`, t, type, src, data });

function v1Fixture(over = {}) {
  return {
    schema: 1,
    key: 'crash.pool_full:b3570:fivem.exe+64C24F',
    family: 'crash.pool_full',
    producer: { tool: 'crash-parser', version: '0.3.0' },
    tenant: null,
    severity: 'HIGH',
    confidence: 'HIGH',
    summary: 'Client crashed on pool exhaustion',
    cause: { headline: 'Server streams more archetypes than the pool holds' },
    location: { module: 'fivem.exe', offset: '0x64C24F', build: '3570', hash: 'fish-mockingbird-two' },
    owner: 'server_owner',
    evidence: [{ kind: 'log_line', ref: 'CitizenFX.log:9278968', excerpt: '<<unknown pool>> Pool Full, Size == 200' }],
    privacy: { redacted: true, classes: ['A'] },
    contract_version: '1.0',
    detected_at: NOW,
    ...over,
  };
}

test('a well-formed v1 finding validates and gets defaults', () => {
  const r = validateFinding(v1Fixture());
  assert.equal(r.ok, true);
  assert.equal(r.finding.status, 'open');
  assert.equal(r.finding.count, 1);
});

test('unknown fields are rejected (strict)', () => {
  const r = validateFinding(v1Fixture({ score: 42 }));
  assert.equal(r.ok, false);
  assert.equal(r.error.code, 'invalid_finding');
});

test('family must be dotted lowercase', () => {
  const r = validateFinding(v1Fixture({ family: 'PoolFull' }));
  assert.equal(r.ok, false);
  assert.equal(r.error.field, 'family');
});

test('privacy gate: a webhook URL anywhere fails with the field named, never the value', () => {
  const r = validateFinding(v1Fixture({
    evidence: [{ kind: 'log_line', ref: 'x', excerpt: 'https://discord.com/api/webhooks/123456/abcDEF_ghi' }],
  }));
  assert.equal(r.ok, false);
  assert.equal(r.error.code, 'privacy_violation');
  assert.equal(r.error.field, 'evidence[0].excerpt');
  assert.ok(!r.error.detail.includes('abcDEF'), 'detail must not echo the value');
});

test('privacy gate: a raw license identifier in a summary is refused', () => {
  const r = validateFinding(v1Fixture({ summary: 'player license:0a1b2c3d4e5f did a thing' }));
  assert.equal(r.ok, false);
  assert.equal(r.error.code, 'privacy_violation');
});

test('assertNoSecrets returns the pattern name, or null', () => {
  assert.equal(assertNoSecrets('sv_licenseKey "abcdefgh12345678"'), 'sv_licenseKey');
  assert.equal(assertNoSecrets('mysql://root:pw@localhost/db'), 'db_uri');
  assert.equal(assertNoSecrets('Pool Full, Size == 200'), null);
  assert.equal(assertNoSecrets(''), null);
});

test('legacy econ-anomaly output normalizes to a valid v1 finding', () => {
  const events = [];
  for (let i = 0; i < 60; i++) {
    events.push(evt('econ.txn', NOW - 60_000 + i * 1000,
      { player: 'Player_4471', direction: 'in', amount: 2500, source: 'unknown', balance_after: 0 }, 'bsd_banking'));
  }
  const legacy = analyze(events, { now: NOW });
  assert.ok(legacy.length >= 1, 'fixture should trigger the detector');
  const f = normalizeLegacy(legacy[0]);
  const r = validateFinding(f);
  assert.equal(r.ok, true, JSON.stringify(r.error));
  assert.equal(r.finding.family, 'econ.anomaly');
  assert.equal(r.finding.owner, 'server_owner');
  assert.equal(r.finding.subject.player, 'Player_4471');
  assert.equal(typeof r.finding.metrics.amount, 'number');
});

test('legacy hitch-diagnosis output normalizes with alternatives and MED→MEDIUM', () => {
  const events = [];
  const t0 = NOW - 120_000;
  events.push(evt('perf.resmon', t0 - 5000, { resource: 'housing', avg_ms: 12, peak_ms: 40, samples: 30 }));
  events.push(evt('server.hitch', t0, { ms: 320, players: 50, active_resources: 200 }));
  events.push(evt('server.hitch', t0 + 30_000, { ms: 610, players: 50, active_resources: 200 }));
  const legacy = diagnose(events, { now: NOW });
  assert.ok(legacy.length >= 1);
  const f = normalizeLegacy(legacy[0]);
  const r = validateFinding(f);
  assert.equal(r.ok, true, JSON.stringify(r.error));
  assert.equal(r.finding.family, 'perf.hitch_issue');
  assert.ok(['MEDIUM', 'HIGH', 'CRITICAL'].includes(r.finding.severity));
  assert.ok(['LOW', 'MEDIUM', 'HIGH'].includes(r.finding.confidence));
  assert.ok(r.finding.count >= 1);
});

test('normalizeLegacy is idempotent on v1 input', () => {
  const f = v1Fixture();
  assert.deepEqual(normalizeLegacy(f), f);
});
