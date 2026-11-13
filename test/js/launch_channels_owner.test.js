// Structural gate: the Android code names the launch channels (`shortcuts`,
// `share_intent`) only in LaunchChannels.kt, which every engine registers.
//
// The wake's engine once kept its own copy of both names and of the list of
// launch queries the activity answered, so a query added to the activity
// went unanswered in a wake. The queries are now a `LaunchSource` both
// engines implement, which the compiler holds; a second place naming the
// channels is what this refuses (rung 5: Kotlin cannot stop a string).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code, lineAt } = require('./helpers/source');

const ROOT = 'android/app/src/main/kotlin';
const OWNER = `${ROOT}/org/codeberg/theoden8/webspace/LaunchChannels.kt`;
const NAMED = /"org\.codeberg\.theoden8\.webspace\/(?:shortcuts|share_intent)"/g;

function named(rel, src) {
  const text = code(src);
  return [...src.matchAll(NAMED)]
    .filter((m) => text.slice(m.index, m.index + 1) === '"')
    .map((m) => `${rel}:${lineAt(src, m.index)}`);
}

test('only LaunchChannels.kt names the launch channels', () => {
  const found = files(ROOT, /\.kt$/)
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => named(rel, read(rel)));
  assert.deepEqual(found, [], 'register them through LaunchChannels.register');
  assert.equal(named(OWNER, read(OWNER)).length, 2, `${OWNER} must name both`);
});

test('planted: a second copy of a channel name is caught, a comment is not', () => {
  assert.deepEqual(
    named('planted.kt', 'private const val SHARE = "org.codeberg.theoden8.webspace/share_intent"\n'),
    ['planted.kt:1']);
  assert.deepEqual(named('planted.kt', '// "org.codeberg.theoden8.webspace/shortcuts"\n'), []);
});
