// Structural gate: a test fixture's socket errors must not fail a test.
//
// The integration tests stand up a loopback server so a webview has
// something to load. An unhandled error on that server's stream is an
// uncaught async error, and `flutter_test` reports it against whichever
// test finished last -- so a socket hiccup in the fixture fails an
// unrelated assertion, under the banner "this test failed after it had
// already completed". That is what a macOS run cost once: errno 22 out of
// `_HttpServer.listen` in `page_zoom_test`, in a run about something else
// entirely, and every fixture in the directory had the same gap.
//
// `listenFixture` (integration_test/fixture_server.dart) is the one place
// that decides what to do with those errors. This test fails if a fixture
// subscribes directly instead, which is how the gap would come back.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const dir = path.join(repoRoot, 'integration_test');

const files = fs
  .readdirSync(dir)
  .filter((f) => f.endsWith('_test.dart'))
  .map((f) => ({ name: f, text: fs.readFileSync(path.join(dir, f), 'utf8') }));

const withFixtures = files.filter((f) =>
  /\b(?:HttpServer|ServerSocket)\.bind\b/.test(f.text),
);

test('the integration tests still stand up server fixtures', () => {
  // Guards the filter: if the suite stops binding servers, or the call is
  // spelled differently, every assertion below would pass vacuously.
  assert.ok(
    withFixtures.length > 0,
    'no integration test binds a server; has the fixture pattern changed?',
  );
});

test('every server fixture subscribes through listenFixture', () => {
  for (const { name, text } of withFixtures) {
    // A bare `.listen(` on the server or an accepted socket, where the
    // subscription is not this file's own error-handling one.
    const direct = [...text.matchAll(/^\s*(\w+!?)\.listen\(/gm)].filter(
      (m) => !/onError/.test(text.slice(m.index, m.index + 400)),
    );
    assert.deepEqual(
      direct.map((m) => m[1]),
      [],
      `integration_test/${name} subscribes to a fixture stream directly. ` +
        `Use listenFixture(...) from fixture_server.dart, or attach an ` +
        `onError of its own: an unhandled socket error fails whichever ` +
        `test finished last.`,
    );
  }
});
