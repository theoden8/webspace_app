// Completeness gate for the anti-fingerprinting surface (rung 5: source text;
// no type says a JS property patch is catalogued). It holds the catalog
// docs/security/fingerprint-surface.tsv to what lib/js/anti_fingerprinting.js
// actually patches: the set of property/method tokens the shim installs MUST
// equal the set of catalog rows marked `covered`. So the shim cannot gain
// coverage of a new surface (it fails until the surface is catalogued) or lose
// coverage of an existing one (the row's token stops being patched) without the
// catalog being updated to match. Open gaps live in the catalog as `open` rows,
// which are intentionally NOT patched.
//
// Break it on purpose: patch a new getter in the shim without a catalog row, or
// delete a patch whose row says covered — this test fails naming the token.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const SHIM = fs.readFileSync(
  path.join(ROOT, 'lib', 'js', 'anti_fingerprinting.js'), 'utf8');
const CATALOG = fs.readFileSync(
  path.join(ROOT, 'docs', 'security', 'fingerprint-surface.tsv'), 'utf8');

// Every token the shim patches, across the idioms it uses to install a patch:
//   defineGetterOnProto(X, 'tok', ...) / defineGetterFnOnProto(X, 'tok', ...)
//   correct('tok', value)                        (navigator.connection values)
//   asNative(function tok(...) {...}, ...)        (wrapped methods / getters)
//   asNative(ref, 'tok')                          (by-reference, e.g. matchMedia)
//   Object.defineProperty(X, 'tok', ...)          (literal-keyed defines)
// A define with a variable key (the helper internals' `name`/`propName`) carries
// no literal and is correctly not matched.
function patchedTokens(src) {
  const found = new Set();
  const collect = (re) => {
    for (const m of src.matchAll(re)) found.add(m[1]);
  };
  collect(/\bdefineGetter(?:Fn)?OnProto\(\s*[^,]+,\s*'([a-zA-Z][a-zA-Z0-9]*)'/g);
  collect(/\bcorrect\(\s*'([a-zA-Z][a-zA-Z0-9]*)'/g);
  collect(/\basNative\(\s*function\s+([a-zA-Z][a-zA-Z0-9]*)/g);
  collect(/\basNative\(\s*[A-Za-z_$][A-Za-z0-9_$]*\s*,\s*'([a-zA-Z][a-zA-Z0-9]*)'/g);
  collect(/\bObject\.defineProperty\(\s*[^,]+,\s*'([a-zA-Z][a-zA-Z0-9]*)'/g);
  return found;
}

function catalogRows(tsv) {
  return tsv
    .split('\n')
    .filter((l) => l && !l.startsWith('#') && !l.startsWith('token\t'))
    .map((l) => {
      const [token, group, api, status, mode, worker, spec, ...notes] = l.split('\t');
      return { token, group, api, status, mode, worker, spec, notes: notes.join('\t') };
    });
}

const rows = catalogRows(CATALOG);
const covered = new Set(rows.filter((r) => r.status === 'covered').map((r) => r.token));
const patched = patchedTokens(SHIM);

test('catalog rows are well formed', () => {
  const seen = new Set();
  for (const r of rows) {
    assert.ok(r.token, `empty token in row: ${JSON.stringify(r)}`);
    assert.ok(!seen.has(r.token), `duplicate catalog token: ${r.token}`);
    seen.add(r.token);
    assert.ok(['covered', 'open', 'n-a'].includes(r.status),
      `bad status "${r.status}" for ${r.token}`);
    assert.ok(r.group && r.api, `row ${r.token} missing group/api`);
  }
});

test('every surface the shim patches is catalogued as covered (no silent gain)', () => {
  const uncatalogued = [...patched].filter((t) => !covered.has(t)).sort();
  assert.deepEqual(uncatalogued, [],
    'the shim patches these tokens but no catalog row marks them covered '
    + '(add a covered row, or flip an open row): ' + uncatalogued.join(', '));
});

test('every covered catalog row is still patched by the shim (no silent loss)', () => {
  const unpatched = [...covered].filter((t) => !patched.has(t)).sort();
  assert.deepEqual(unpatched, [],
    'these catalog rows say covered but the shim no longer patches them '
    + '(a coverage regression, or a stale row): ' + unpatched.join(', '));
});

test('an open gap is not silently patched (flip its status when it is)', () => {
  const open = new Set(rows.filter((r) => r.status === 'open').map((r) => r.token));
  const nowPatched = [...open].filter((t) => patched.has(t)).sort();
  assert.deepEqual(nowPatched, [],
    'these open-gap tokens are now patched; set their status to covered: '
    + nowPatched.join(', '));
});
