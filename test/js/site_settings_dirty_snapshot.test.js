// Dirty-snapshot registration gate (EDIT-009 / BUG-006). The site settings
// screen decides "warn before discarding unsaved changes?" by diffing the
// form against a hand-enumerated snapshot map (_currentSnapshot). A form
// field that is loaded in _loadFromModel but never registered in the
// snapshot is invisible to the diff: editing only that field lets the pop
// through silently and the change is dropped — exactly how kiosk mode
// (#454) regressed after the warning shipped. This gate makes the next
// forgotten field fail CI instead of shipping.
//
// Rule: every instance field assigned in _loadFromModel() must be
// referenced in _currentSnapshot(), unless it is fully derived from a
// field that already is (allowlist below, each entry justified).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const SETTINGS = 'lib/screens/settings.dart';

// Derived fields: excluded from the snapshot on purpose. Every entry must
// say which registered field makes it redundant.
const DERIVED = {
  // UI-only mirror of _liveLocationGranularity (registered): every toggle
  // of the approximate sub-switch also rewrites the granularity, and the
  // switch is hidden while granularity is gsm, so it can never be the
  // only difference.
  _liveGpsApproximate: '_liveLocationGranularity',
};

function extractBody(src, headerRe, label) {
  const m = headerRe.exec(src);
  assert.ok(m, `${label} not found in ${SETTINGS}`);
  const open = src.indexOf('{', m.index);
  assert.ok(open >= 0, `${label}: no opening brace`);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return src.slice(open + 1, i);
    }
  }
  assert.fail(`${label}: unbalanced braces`);
}

test('settings form fields loaded from the model are all dirty-tracked', () => {
  const src = fs.readFileSync(path.join(repoRoot, SETTINGS), 'utf8');

  const loadBody = extractBody(
    src,
    /void\s+_loadFromModel\s*\(\s*\)\s*\{/,
    '_loadFromModel',
  );
  const snapshotBody = extractBody(
    src,
    /Map<String,\s*Object\?>\s+_currentSnapshot\s*\(\s*\)\s*(?:=>)?\s*\{/,
    '_currentSnapshot',
  );

  // Assignment targets: `_field = ...` or `_field.member = ...` at the
  // start of a statement line. `=(?!=)` keeps `==` comparisons on the RHS
  // from matching.
  const fields = new Set();
  for (const line of loadBody.split('\n')) {
    const m = /^\s*(_[A-Za-z0-9_]+)(?:\.[A-Za-z0-9_]+)?\s*=(?!=)/.exec(line);
    if (m) fields.add(m[1]);
  }
  assert.ok(
    fields.size >= 20,
    `expected _loadFromModel to assign many form fields, got ${fields.size} — extraction broke?`,
  );

  const missing = [];
  for (const f of fields) {
    if (f in DERIVED) {
      assert.ok(
        new RegExp(`\\b${DERIVED[f]}\\b`).test(snapshotBody),
        `${f} is allowlisted as derived from ${DERIVED[f]}, but ${DERIVED[f]} is not in _currentSnapshot`,
      );
      continue;
    }
    if (!new RegExp(`\\b${f}\\b`).test(snapshotBody)) missing.push(f);
  }
  assert.deepEqual(
    missing,
    [],
    `form fields loaded in _loadFromModel but absent from _currentSnapshot ` +
      `(unsaved edits to them are silently dropped on back — BUG-006): ${missing.join(', ')}. ` +
      `Register each in _currentSnapshot, or add it to DERIVED here with a justification.`,
  );
});
