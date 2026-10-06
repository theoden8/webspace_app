// Dirty-snapshot registration gate (EDIT-009 / BUG-006). The site settings
// screen decides "warn before discarding unsaved changes?" by comparing the
// form against a hand-enumerated snapshot record (DirtyGuard.snapshot). A
// form field that is loaded in _loadFromModel but never put in the record is
// invisible to the comparison: editing only that field lets the pop through
// silently and the change is dropped — exactly how kiosk mode (#454)
// regressed after the warning shipped. The record makes the comparison
// exact; this gate makes the next forgotten field fail CI instead of shipping.
//
// Rule: every instance field assigned in _loadFromModel() must be
// referenced in snapshot(), unless it is fully derived from a
// field that already is (allowlist below, each entry justified). A form
// object edited in place (`_proxySettings.type = ...`) is registered member
// by member: the object being in the snapshot says nothing about a member
// that is not, which is how the Tor exit country escaped the rule above.

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

function extractBody(src, headerRe, label, [open, close] = ['{', '}']) {
  const m = headerRe.exec(src);
  assert.ok(m, `${label} not found in ${SETTINGS}`);
  const start = src.indexOf(open, m.index + m[0].length - 1);
  assert.ok(start >= 0, `${label}: no opening ${open}`);
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    if (src[i] === open) depth++;
    else if (src[i] === close) {
      depth--;
      if (depth === 0) return src.slice(start + 1, i);
    }
  }
  assert.fail(`${label}: unbalanced ${open}${close}`);
}

const snapshotBody = (src) => extractBody(
  src,
  /Record\s+snapshot\s*\(\s*\)\s*=>\s*\(/,
  'snapshot',
  ['(', ')'],
);

test('settings form fields loaded from the model are all dirty-tracked', () => {
  const src = fs.readFileSync(path.join(repoRoot, SETTINGS), 'utf8');

  const loadBody = extractBody(
    src,
    /void\s+_loadFromModel\s*\(\s*\)\s*\{/,
    '_loadFromModel',
  );
  const snapshot = snapshotBody(src);

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
        new RegExp(`\\b${DERIVED[f]}\\b`).test(snapshot),
        `${f} is allowlisted as derived from ${DERIVED[f]}, but ${DERIVED[f]} is not in snapshot()`,
      );
      continue;
    }
    if (!new RegExp(`\\b${f}\\b`).test(snapshot)) missing.push(f);
  }
  assert.deepEqual(
    missing,
    [],
    `form fields loaded in _loadFromModel but absent from snapshot() ` +
      `(unsaved edits to them are silently dropped on back — BUG-006): ${missing.join(', ')}. ` +
      `Register each in snapshot(), or add it to DERIVED here with a justification.`,
  );
});

test('form objects edited in place are dirty-tracked member by member', () => {
  const src = fs.readFileSync(path.join(repoRoot, SETTINGS), 'utf8');
  const snapshot = snapshotBody(src);

  const members = new Set();
  for (const m of src.matchAll(/^\s*(_[A-Za-z0-9_]+\.[A-Za-z0-9_]+)\s*=(?!=)/gm)) {
    members.add(m[1]);
  }
  assert.ok(
    members.has('_proxySettings.type'),
    'expected the proxy type to be edited in place — extraction broke?',
  );

  const missing = [...members].filter(
    (member) => !new RegExp(`${member.replace('.', '\\.')}\\b`).test(snapshot),
  );
  assert.deepEqual(
    missing,
    [],
    `members written in place but absent from snapshot() (an edit to ` +
      `only that member is dropped on back without a prompt — BUG-006): ` +
      `${missing.join(', ')}. Register each in snapshot().`,
  );
});

// The same symptom through a screen with no guard at all: the user script and
// webspace editors had a Save action and popped on back, dropping the edit.
test('every screen with a Save action guards its edits', () => {
  const dir = path.join(repoRoot, 'lib', 'screens');
  const editors = fs.readdirSync(dir)
    .filter((f) => f.endsWith('.dart'))
    .map((f) => [`lib/screens/${f}`, fs.readFileSync(path.join(dir, f), 'utf8')])
    .filter(([, src]) => /\b(?:void|Future<void>)\s+_save(?:Settings)?\s*\(/.test(src));
  assert.ok(editors.length >= 4, `found only ${editors.length} editors; the scan broke`);
  const unguarded = editors
    .filter(([, src]) => !/\bwith\s+DirtyGuard</.test(src))
    .map(([rel]) => rel);
  assert.deepEqual(unguarded, [],
    'mix in DirtyGuard (lib/widgets/dirty_guard.dart) and wrap the screen in guardPop');
});
