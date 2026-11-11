const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// ViewKey names one native webview for its life; DL-008 ("a page acts only on
// its own view's downloads") and SHARE-017 compare views by the key, so two
// live views must never share one. identityHashCode is not unique (two live
// objects can share one, and a value is reused after a collection), and a
// collision cannot be forced in a Dart test, so this source gate is the rung-5
// catch for a mutant that keys by hash; test/view_key_test.dart pins the
// observable behaviour (distinct views -> distinct keys, memoised per view).

const SRC = fs.readFileSync(
  path.join(__dirname, '..', '..', 'lib', 'services', 'view_key.dart'), 'utf8');

// Strip comments so the prose that explains WHY identityHashCode is avoided
// does not trip the check that the CODE never calls it.
const CODE = SRC.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');

test('ViewKey.of mints a unique key, never identityHashCode', () => {
  assert.doesNotMatch(CODE, /identityHashCode/,
    'ViewKey must not key on identityHashCode: it collides, which would let '
    + 'two views share a key (DL-008/SHARE-017). Mint a unique id instead.');
  assert.match(SRC, /Expando<ViewKey>/,
    'ViewKey memoises per platform controller via a weak Expando, so the key '
    + 'is stable per view and released when the controller is collected.');
  assert.match(SRC, /_next\+\+/,
    'ViewKey mints a unique monotonic id, so distinct views never collide.');
});

test('ViewKey has no construction from a String outside the type', () => {
  // The only representation constructor is private (`._`) and the only entry
  // is `ViewKey.of(controller)`, which reads the platform controller. A page
  // string can never become a ViewKey (condition for DL-008's view binding).
  assert.doesNotMatch(SRC, /ViewKey\.parse|factory ViewKey\.fromString/,
    'ViewKey must not parse from a String.');
  assert.match(SRC, /extension type const ViewKey\._\(String raw\)/,
    'ViewKey keeps a private representation constructor.');
});
