const test = require('node:test');
const assert = require('node:assert');
const { normalizeSource, isUnsourced } = require('./provenance');

test('every way of saying "no reason" folds to unknown', () => {
  for (const s of [undefined, null, '', '  ', 'unknown', 'Unknown', 'UNKNOWN', ' none ', 'N/A', 'nil', 42]) {
    assert.strictEqual(normalizeSource(s), 'unknown', `input ${JSON.stringify(s)}`);
    assert.ok(isUnsourced(s));
  }
});

test('a real reason is kept, trimmed, case intact', () => {
  assert.strictEqual(normalizeSource(' bsd_banking:withdraw '), 'bsd_banking:withdraw');
  assert.strictEqual(normalizeSource('Bank deposit'), 'Bank deposit');
  assert.ok(!isUnsourced('qbx_core:paycheck'));
});
