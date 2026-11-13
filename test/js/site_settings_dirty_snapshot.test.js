// Dirty-snapshot registration gate (EDIT-009 / BUG-006). The site settings
// screen decides "warn before discarding unsaved changes?" by comparing the
// form against a snapshot record (DirtyGuard.snapshot). A form field that is
// loaded in _loadFromModel but never put in the record is invisible to the
// comparison: editing only that field lets the pop through silently and the
// change is dropped, as kiosk mode (#454) and the Tor exit country did.
//
// What each Site screen edits is one record field of the screen
// (PrivacyChoices, BehaviourChoices, PermissionChoices, NetworkChoices), so
// record equality covers every setting inside it and this gate checks none
// of them. It is left with what a type cannot say: that each field the
// screen keeps outside those records (the text controllers, the language,
// zoom and theme, the live-location flag, and each record itself) is in the
// snapshot.
//
// Rule: every instance field assigned in _loadFromModel() must be
// referenced in snapshot().

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const SETTINGS = 'lib/screens/settings.dart';

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

/** The fields [src]'s _loadFromModel assigns, and those its snapshot misses. */
function unregistered(src) {
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
  const missing = [...fields].filter(
    (f) => !new RegExp(`\\b${f}\\b`).test(snapshot),
  );
  return { fields, missing };
}

test('settings form fields loaded from the model are all dirty-tracked', () => {
  const src = fs.readFileSync(path.join(repoRoot, SETTINGS), 'utf8');
  const { fields, missing } = unregistered(src);
  for (const record of ['_privacy', '_behaviour', '_permissions', '_network']) {
    assert.ok(fields.has(record),
      `expected _loadFromModel to load ${record} — extraction broke?`);
  }
  assert.deepEqual(
    missing,
    [],
    `form fields loaded in _loadFromModel but absent from snapshot() ` +
      `(unsaved edits to them are silently dropped on back — BUG-006): ${missing.join(', ')}. ` +
      `Register each in snapshot(), or move it into its Site screen's choices record.`,
  );
});

// The planted mistake: the screen as it is, with one record left out of the
// snapshot, as kiosk mode was left out before the records.
test('a loaded field left out of the snapshot is reported', () => {
  const src = fs.readFileSync(path.join(repoRoot, SETTINGS), 'utf8');
  const planted = src.replace(/\n\s*behaviour: _behaviour,/, '');
  assert.notEqual(planted, src, 'the snapshot no longer lists _behaviour; replant');
  assert.deepEqual(unregistered(planted).missing, ['_behaviour']);
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
