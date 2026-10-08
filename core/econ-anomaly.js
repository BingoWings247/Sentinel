// core/econ-anomaly.js
// Sentinel detection module: economy anomalies via the provenance doctrine.
// PURE — events in, findings out. No Express, no DB, no globals, no clocks
// it doesn't receive. This purity is what makes it testable and portable.
//
// Doctrine (scalpel, not shotgun): we do not flag "fast money" — we flag
// money that lacks a cause. Legitimate gains have provenance (a source).
// Outcomes without causes have no innocent explanation.

const { isUnsourced } = require('./provenance');

const DEFAULTS = {
  windowMs: 10 * 60 * 1000,   // look-back window: 10 minutes
  gainThreshold: 100_000,     // net gain that earns scrutiny
  minTxns: 20,                // repetition floor — below this, never fires
  similarityBand: 0.05,       // amounts within ±5% of the median count as "near-identical"
  similarityRatio: 0.75,      // fraction of txns that must be near-identical
  unsourcedRatio: 0.5,        // fraction of gain lacking provenance => HIGH confidence
};

/**
 * Analyze events for economy anomalies.
 * @param {Array}  events - wire-protocol events (any types; non-econ ignored)
 * @param {Object} opts   - overrides of DEFAULTS; opts.now = analysis time (ms)
 * @returns {Array} findings
 */
function analyze(events, opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };
  const now = cfg.now ?? Date.now();
  const from = now - cfg.windowMs;

  // 1. Collect in-window incoming econ txns, grouped by player
  const byPlayer = new Map();
  for (const ev of events) {
    if (ev.type !== 'econ.txn') continue;
    if (ev.t < from || ev.t > now) continue;
    const d = ev.data || {};
    if (d.direction !== 'in') continue;
    const player = d.player || 'unknown_player';
    if (!byPlayer.has(player)) byPlayer.set(player, []);
    byPlayer.get(player).push(ev);
  }

  // 2. Evaluate each player against the doctrine
  const findings = [];
  for (const [player, txns] of byPlayer) {
    if (txns.length < cfg.minTxns) continue;

    const amounts = txns.map((e) => e.data.amount || 0);
    const totalGain = amounts.reduce((s, a) => s + a, 0);
    if (totalGain < cfg.gainThreshold) continue;

    // Repetition: how many amounts sit within ±band of the median?
    const median = medianOf(amounts);
    const nearIdentical = amounts.filter(
      (a) => median > 0 && Math.abs(a - median) / median <= cfg.similarityBand
    ).length;
    const repetition = nearIdentical / txns.length;
    if (repetition < cfg.similarityRatio) continue;

    // Provenance: how much of the gain has no source?
    const unsourcedGain = txns
      .filter((e) => isUnsourced(e.data.source))
      .reduce((s, e) => s + (e.data.amount || 0), 0);
    const unsourced = totalGain > 0 ? unsourcedGain / totalGain : 0;

    // Confidence per doctrine:
    //  - repetitive + large + UNSOURCED  => HIGH (no innocent explanation)
    //  - repetitive + large + sourced    => MEDIUM (odd, but has a stated cause —
    //    could be a broken payout loop; a human should look, not panic)
    const confidence = unsourced >= cfg.unsourcedRatio ? 'HIGH' : 'MEDIUM';

    const windowStart = Math.min(...txns.map((e) => e.t));
    const windowEnd = Math.max(...txns.map((e) => e.t));

    findings.push({
      // Stable key: same player + same burst window => same finding (dedupe handle)
      key: `econ.anomaly:${player}:${Math.floor(windowStart / 60000)}`,
      type: 'econ.anomaly',
      player,
      window: { from: windowStart, to: windowEnd },
      amount: totalGain,
      txn_count: txns.length,
      median_amount: median,
      repetition_ratio: +repetition.toFixed(2),
      unsourced_ratio: +unsourced.toFixed(2),
      confidence,
      evidence: txns.map((e) => e.id),
      summary:
        `${player} gained $${totalGain.toLocaleString()} across ${txns.length} ` +
        `near-identical transactions (median $${Math.round(median).toLocaleString()}); ` +
        `${Math.round(unsourced * 100)}% of the gain has no income source.`,
      detected_at: now,
    });
  }

  return findings;
}

function medianOf(nums) {
  const s = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

module.exports = { analyze, DEFAULTS };