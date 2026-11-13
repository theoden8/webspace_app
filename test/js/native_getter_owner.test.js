// Structural gate: a getter a page script installs stringifies as native code.
//
// A shim's accessor is read back by the page it hides from: `Object.
// getOwnPropertyDescriptor(Navigator.prototype, 'doNotTrack').get + ''` that
// prints JavaScript names the shim. `nativeGetter` (lib/js/_native_getter.js)
// installs one through `asNative`; do_not_track.js and media_session.js wrote
// their own and printed their source. A function literal handed straight to
// `get:` is that mistake, so it is what this refuses (rung 5: the scripts are
// plain JavaScript, with no type to say a function is disguised).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, jsFiles, code, lineAt } = require('./helpers/source');

// A getter takes no parameters; `get: function(url)` is a method named get.
const BARE = /\bget\s*:\s*function\s*\w*\s*\(\s*\)/g;

function bareGetters(rel, src) {
  const text = code(src);
  return [...text.matchAll(BARE)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('no page script installs a getter that prints its own source', () => {
  const found = jsFiles().flatMap((rel) => bareGetters(rel, read(rel)));
  assert.deepEqual(found, [],
    'install it with nativeGetter(target, name, read), or wrap it in asNative');
});

test('planted: a bare function getter is caught; an asNative one and a method named get are not', () => {
  assert.deepEqual(
    bareGetters('planted.js', "Object.defineProperty(o, 'x', { get: function() { return 1; } });\n"),
    ['planted.js:1']);
  assert.deepEqual(
    bareGetters('planted.js', "Object.defineProperty(o, 'x', { get: asNative(function() {}, 'get x') });\n"),
    []);
  assert.deepEqual(bareGetters('planted.js', 'var m = { get: function(url) { return url; } };\n'), []);
});
