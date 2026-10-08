// ingest/privacy.js
// The ingest half of the data contract's redaction rule: the agent strips
// secrets (Class S) and raw identifiers (Class I) before sending, and ingest
// checks again before anything is stored. A match rejects the event and names
// the pattern, never the value (docs/data-contract-engineering.md, item 6).

const { assertNoSecrets } = require('../core/finding');

const MAX_DEPTH = 6;

// Returns null when clean, or { path, pattern } for the first match.
function scanForSecrets(value, path = 'data', depth = 0) {
  if (depth > MAX_DEPTH || value == null) return null;
  if (typeof value === 'string') {
    const hit = assertNoSecrets(value);
    return hit ? { path, pattern: hit } : null;
  }
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const hit = scanForSecrets(value[i], `${path}.${i}`, depth + 1);
      if (hit) return hit;
    }
    return null;
  }
  if (typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      // "password=hunter22" style secrets only show up when key and value are read together.
      if (typeof v === 'string') {
        const pair = assertNoSecrets(`${k}=${v}`);
        if (pair) return { path: `${path}.${k}`, pattern: pair };
      }
      const hit = scanForSecrets(v, `${path}.${k}`, depth + 1);
      if (hit) return hit;
    }
  }
  return null;
}

module.exports = { scanForSecrets };
