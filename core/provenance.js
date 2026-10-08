// core/provenance.js
// One meaning for "no reason given". Qbox fills a missing money reason with
// "unknown"; scripts pass "Unknown", "none", "" and the like. They all mean
// the same thing to detection: nobody said where the money came from.
// PURE: strings in, strings out.

const NO_REASON = new Set(['', 'unknown', 'none', 'n/a', 'nil', 'null', 'undefined']);

/** The stated cause, trimmed, or "unknown" when there isn't one. */
function normalizeSource(source) {
  if (typeof source !== 'string') return 'unknown';
  const s = source.trim();
  return NO_REASON.has(s.toLowerCase()) ? 'unknown' : s;
}

/** True when an econ event has no stated cause. */
function isUnsourced(source) {
  return normalizeSource(source) === 'unknown';
}

module.exports = { normalizeSource, isUnsourced };
