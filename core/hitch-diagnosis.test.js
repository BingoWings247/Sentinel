// core/hitch-diagnosis.test.js
// Run from project root:  node --test
// Synthetic hitch scenarios proving the ranked-causes engine.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { diagnose } = require('./hitch-diagnosis');

const NOW = 1_753_500_000_000;
let n = 0;
const id = () => `evt_hd_${++n}`;

const hitch = (t, ms = 600, players = 30) => ({
  id: id(), t, type: 'server.hitch', src: 'server',
  data: { ms, players, active_resources: 140 },
});
const resmon = (t, resource, avg, peak) => ({
  id: id(), t, type: 'perf.resmon', src: resource,
  data: { resource, avg_ms: avg, peak_ms: peak, samples: 30 },
});
const restart = (t, resource) => ({
  id: id(), t, type: 'server.resource', src: 'server',
  data: { resource, action: 'restart', by: 'Dev_Marcus' },
});
const txn = (t) => ({
  id: id(), t, type: 'econ.txn', src: 'bsd_banking',
  data: { player: 'Player_4471', direction: 'in', amount: 2400, source: 'unknown', balance_after: 0 },
});

/** Calm background: hours of normal resmon windows for two resources. */
function calmBackground() {
  const events = [];
  for (let i = 0; i < 60; i++) {
    const t = NOW - 60 * 60000 + i * 60000;
    events.push(resmon(t, 'esx_inventory', 1.2, 4));
    events.push(resmon(t, 'oxmysql', 0.5, 3));
  }
  return events;
}

// ---- tests ---------------------------------------------------------------

test('quiet stream produces no findings', () => {
  assert.equal(diagnose(calmBackground()).length, 0);
});

test('hitch with a resmon spike names the resource as top cause', () => {
  const events = [
    ...calmBackground(),
    resmon(NOW - 20_000, 'esx_inventory', 5.1, 38), // spiked ~10x its normal peak
    hitch(NOW, 812, 47),
  ];
  const findings = diagnose(events);
  assert.equal(findings.length, 1);
  const f = findings[0];
  assert.equal(f.type, 'perf.hitch_issue');
  assert.equal(f.top_cause, 'resmon:esx_inventory');
  assert.equal(f.confidence, 'HIGH');
  assert.ok(f.causes[0].detail.includes('esx_inventory'));
  assert.ok(f.summary.includes('812'));
});

test('event flood before a hitch is diagnosed as the cause', () => {
  const events = [...calmBackground()];
  for (let i = 0; i < 200; i++) events.push(txn(NOW - 40_000 + i * 150)); // burst
  events.push(hitch(NOW, 950, 40));
  const findings = diagnose(events);
  assert.equal(findings.length, 1);
  assert.equal(findings[0].top_cause, 'flood:econ.txn');
  assert.equal(findings[0].confidence, 'HIGH');
  assert.ok(findings[0].causes[0].detail.includes('econ.txn'));
});

test('recent restart shows up among the causes', () => {
  const events = [
    ...calmBackground(),
    restart(NOW - 30_000, 'esx_inventory'),
    hitch(NOW, 500, 30),
  ];
  const findings = diagnose(events);
  assert.equal(findings.length, 1);
  const kinds = findings[0].causes.map((c) => c.kind);
  assert.ok(kinds.includes('restart'));
});

test('recurring hitches with the same suspect group into ONE issue', () => {
  const events = [...calmBackground()];
  for (let k = 0; k < 3; k++) {
    const t = NOW - k * 5 * 60000;
    events.push(resmon(t - 15_000, 'esx_inventory', 6, 40 + k));
    events.push(hitch(t, 700 + k * 50, 44));
  }
  const findings = diagnose(events);
  assert.equal(findings.length, 1, 'three hitches, one issue');
  assert.equal(findings[0].count, 3);
  assert.equal(findings[0].top_cause, 'resmon:esx_inventory');
  assert.ok(findings[0].worst_ms >= 800);
  assert.equal(findings[0].evidence.length, 3);
});

test('hitch with nothing abnormal falls back honestly', () => {
  const events = [...calmBackground(), hitch(NOW, 400, 20)];
  const findings = diagnose(events);
  assert.equal(findings.length, 1);
  assert.equal(findings[0].top_cause, 'unattributed');
  assert.ok(findings[0].summary.includes('external'));
});

test('heavy player count appears as LOW background cause, never headline over a spike', () => {
  const events = [
    ...calmBackground(),
    resmon(NOW - 10_000, 'oxmysql', 2, 33),
    hitch(NOW, 600, 60), // busy server AND a spike
  ];
  const findings = diagnose(events);
  const f = findings[0];
  assert.equal(f.causes[0].kind, 'resmon', 'spike outranks load');
  const load = f.causes.find((c) => c.kind === 'load');
  assert.ok(load, 'load listed');
  assert.equal(load.confidence, 'LOW');
});