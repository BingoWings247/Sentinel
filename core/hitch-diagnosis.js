// core/hitch-diagnosis.js
// Sentinel detection module: server hitch diagnosis with ranked probable causes.
// PURE — events in, findings out. No Express, no DB, no real clocks.
//
// The flagship. Nobody in the FiveM ecosystem diagnoses hitches — they show
// charts and let devs guess. We correlate: for each hitch, what was abnormal
// in the window around it? Then we group recurring hitches with the same top
// suspect into one issue (Sentry-style) instead of fourteen separate whines.

const DEFAULTS = {
  lookbackMs: 60_000,        // correlation window before each hitch
  restartWindowMs: 120_000,  // resource restart this recent = suspect
  resmonAbsoluteMs: 20,      // a peak this high is suspicious on its own
  resmonSpikeFactor: 3,      // ...or >= 3x the resource's own median peak
  floodMinCount: 50,         // event-type burst floor
  floodFactor: 4,            // ...and >= 4x the baseline rate
  playerLoadFloor: 45,       // players >= this earns the background LOW cause
};

/**
 * Diagnose server hitches in an event stream.
 * @param {Array}  events - wire-protocol events (all types; hitches found within)
 * @param {Object} opts   - overrides of DEFAULTS
 * @returns {Array} findings — one per ISSUE (grouped hitches), not per hitch
 */
function diagnose(events, opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };

  const hitches = events
    .filter((e) => e.type === 'server.hitch')
    .sort((a, b) => a.t - b.t);
  if (!hitches.length) return [];

  // Pre-compute per-resource median peak across the whole stream (its "normal")
  const peaksByResource = new Map();
  for (const e of events) {
    if (e.type !== 'perf.resmon') continue;
    const r = e.data?.resource;
    if (!r) continue;
    if (!peaksByResource.has(r)) peaksByResource.set(r, []);
    peaksByResource.get(r).push(e.data.peak_ms || 0);
  }
  const medianPeak = new Map(
    [...peaksByResource].map(([r, peaks]) => [r, medianOf(peaks)])
  );

  // ---- Diagnose each hitch individually --------------------------------
  const diagnosed = hitches.map((hitch) => {
    const from = hitch.t - cfg.lookbackMs;
    const windowEvents = events.filter((e) => e.t >= from && e.t <= hitch.t && e !== hitch);
    const causes = [];

    // 1. Resource resmon spike near the hitch
    for (const e of windowEvents) {
      if (e.type !== 'perf.resmon') continue;
      const r = e.data?.resource;
      const peak = e.data?.peak_ms || 0;
      const normal = medianPeak.get(r) || 0;
      const spiked = peak >= cfg.resmonAbsoluteMs || (normal > 0 && peak >= normal * cfg.resmonSpikeFactor);
      if (!spiked) continue;
      causes.push({
        kind: 'resmon',
        id: `resmon:${r}`,
        confidence: peak >= cfg.resmonAbsoluteMs * 1.5 ? 'HIGH' : 'MED',
        magnitude: peak,
        detail: `${r} peaked at ${peak} ms in the minute before the hitch` +
                (normal > 0 ? ` (normal peak ~${Math.round(normal)} ms)` : ''),
        evidence: [e.id],
      });
    }

    // 2. Event-type flood in the lookback window
    const countsByType = new Map();
    for (const e of windowEvents) {
      countsByType.set(e.type, (countsByType.get(e.type) || 0) + 1);
    }
    const streamSpanMs = Math.max(1, events[events.length - 1]?.t - events[0]?.t || 1);
    for (const [type, count] of countsByType) {
      if (type.startsWith('perf.')) continue; // sampling windows aren't floods
      const totalOfType = events.filter((e) => e.type === type).length;
      const expected = (totalOfType / streamSpanMs) * cfg.lookbackMs;
      if (count >= cfg.floodMinCount && count >= expected * cfg.floodFactor) {
        causes.push({
          kind: 'flood',
          id: `flood:${type}`,
          confidence: 'HIGH',
          magnitude: count,
          detail: `${count} ${type} events in the minute before the hitch (~${Math.max(1, Math.round(expected))} expected)`,
          evidence: windowEvents.filter((e) => e.type === type).slice(0, 20).map((e) => e.id),
        });
      }
    }

    // 3. Recent resource restart (GC churn / re-init cost)
    for (const e of windowEvents) {
      if (e.type !== 'server.resource') continue;
      if (hitch.t - e.t > cfg.restartWindowMs) continue;
      causes.push({
        kind: 'restart',
        id: `restart:${e.data?.resource}`,
        confidence: 'MED',
        magnitude: 1,
        detail: `${e.data?.resource} ${e.data?.action || 'restarted'} ${Math.round((hitch.t - e.t) / 1000)}s before the hitch`,
        evidence: [e.id],
      });
    }

    // 4. Background load (never the headline, always worth listing)
    const players = hitch.data?.players || 0;
    if (players >= cfg.playerLoadFloor) {
      causes.push({
        kind: 'load',
        id: 'load:players',
        confidence: 'LOW',
        magnitude: players,
        detail: `${players} players online — OneSync population load`,
        evidence: [],
      });
    }

    // Rank: confidence tier first, magnitude second; cap at 5
    const tier = { HIGH: 3, MED: 2, LOW: 1 };
    causes.sort((a, b) => tier[b.confidence] - tier[a.confidence] || b.magnitude - a.magnitude);

    return { hitch, causes: causes.slice(0, 5) };
  });

  // ---- Group hitches by top suspect into issues (Sentry-style) ---------
  const issues = new Map();
  for (const d of diagnosed) {
    const topId = d.causes[0]?.id || 'unattributed';
    if (!issues.has(topId)) {
      issues.set(topId, {
        key: `perf.hitch_issue:${topId}`,
        type: 'perf.hitch_issue',
        top_cause: topId,
        count: 0,
        first_seen: d.hitch.t,
        last_seen: d.hitch.t,
        worst_ms: 0,
        causes: d.causes,
        evidence: [],
      });
    }
    const issue = issues.get(topId);
    issue.count++;
    issue.first_seen = Math.min(issue.first_seen, d.hitch.t);
    issue.last_seen = Math.max(issue.last_seen, d.hitch.t);
    if ((d.hitch.data?.ms || 0) > issue.worst_ms) {
      issue.worst_ms = d.hitch.data?.ms || 0;
      issue.causes = d.causes; // keep the diagnosis of the worst instance
    }
    issue.evidence.push(d.hitch.id);
  }

  // Finalize: confidence + summary per issue
  return [...issues.values()].map((issue) => {
    const top = issue.causes[0];
    const confidence = top ? top.confidence : 'LOW';
    const headline = top
      ? top.detail
      : 'no abnormal activity found in the window — likely external (host, OS, disk)';
    return {
      ...issue,
      confidence,
      summary:
        `${issue.count} hitch${issue.count > 1 ? 'es' : ''} (worst ${issue.worst_ms} ms) — ` +
        `top probable cause: ${headline}`,
      detected_at: issue.last_seen,
    };
  });
}

function medianOf(nums) {
  if (!nums.length) return 0;
  const s = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

module.exports = { diagnose, DEFAULTS };