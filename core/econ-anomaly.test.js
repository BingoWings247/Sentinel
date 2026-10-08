// core/econ-anomaly.test.js
// Run from project root:  node --test core/
// Node's built-in test runner — zero extra dependencies.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { analyze } = require('./econ-anomaly');

// ---- helpers -------------------------------------------------------------
const NOW = 1_753_400_000_000; // fixed clock: tests never depend on real time
let n = 0;

function txn({ player, amount, source, t, direction = 'in' }) {
  return {
    id: `evt_test_${++n}`,
    t,
    type: 'econ.txn',
    src: 'bsd_banking',
    data: { player, direction, amount, source, balance_after: 0 },
  };
}

/** Varied, sourced income — an honest evening of RP. */
function normalPlay(player) {
  const sources = ['job:police:paycheck', 'sale:qb-vehicleshop', 'transfer:player', 'job:tow:payout'];
  const events = [];
  for (let i = 0; i < 40; i++) {
    events.push(txn({
      player,
      amount: 200 + Math.floor(Math.sin(i * 7) * 150) + i * 90, // varied, drifting amounts
      source: sources[i % sources.length],
      t: NOW - (9 * 60000) + i * 12000,
    }));
  }
  return events;
}

/** A dupe burst: many near-identical gains, no provenance. */
function dupeBurst(player, { count = 200, base = 2400, source = 'unknown' } = {}) {
  const events = [];
  for (let i = 0; i < count; i++) {
    events.push(txn({
      player,
      amount: base + (i % 7), // $2,400 ± $6 — near-identical
      source,
      t: NOW - (4 * 60000) + i * 900,
    }));
  }
  return events;
}

// ---- tests ---------------------------------------------------------------

test('normal play produces zero findings', () => {
  const findings = analyze(normalPlay('Honest_Hank'), { now: NOW });
  assert.equal(findings.length, 0);
});

test('unsourced dupe burst produces one HIGH finding naming the player', () => {
  const events = [...normalPlay('Honest_Hank'), ...dupeBurst('Player_4471')];
  const findings = analyze(events, { now: NOW });

  assert.equal(findings.length, 1);
  const f = findings[0];
  assert.equal(f.player, 'Player_4471');
  assert.equal(f.type, 'econ.anomaly');
  assert.equal(f.confidence, 'HIGH');
  assert.ok(f.amount >= 200 * 2400, `amount was ${f.amount}`);
  assert.ok(f.unsourced_ratio >= 0.99);
  assert.equal(f.evidence.length, f.txn_count);
  assert.ok(f.summary.includes('Player_4471'));
});

test('sourced repetitive burst is MEDIUM, not HIGH (has a stated cause)', () => {
  // Same shape as a dupe, but every txn carries provenance — e.g. a broken
  // paycheck loop. Odd enough to surface; not damning enough to scream.
  const events = dupeBurst('Loop_Larry', { source: 'job:police:paycheck' });
  const findings = analyze(events, { now: NOW });

  assert.equal(findings.length, 1);
  assert.equal(findings[0].confidence, 'MEDIUM');
  assert.equal(findings[0].unsourced_ratio, 0);
});

test('small repetitive gains stay below the floor (no findings)', () => {
  // 30 identical $50 tips — repetitive but trivial. The scalpel ignores it.
  const events = dupeBurst('Tip_Jar_Tina', { count: 30, base: 50 });
  const findings = analyze(events, { now: NOW });
  assert.equal(findings.length, 0);
});

test('events outside the window are ignored', () => {
  const stale = dupeBurst('Old_News_Oscar').map((e) => ({ ...e, t: NOW - 60 * 60000 }));
  const findings = analyze(stale, { now: NOW });
  assert.equal(findings.length, 0);
});
// ---- provenance folding --------------------------------------------------
test('"Unknown" (capital U, as some scripts pass it) counts as unsourced', () => {
  const findings = analyze(dupeBurst('Kaiden', { source: 'Unknown' }), { now: NOW });
  assert.equal(findings.length, 1);
  assert.equal(findings[0].confidence, 'HIGH');
});
