// The per-site proxy gate has to be able to fail (LEAK-003, BUG-014).
//
// `integration_test/proxy_binding_test.dart` is the only tier that observes
// whether a proxy reached the engine, and it reported green through two
// separate reasons why it could not have observed anything:
//
//  1. Its origin was on `127.0.0.1`. Apple never sends a loopback
//     destination through a proxy, so "the proxied load did not reach the
//     origin" was true whether or not the proxy was bound.
//  2. Its second mount reused the same widget position, so Flutter updated
//     the existing `InAppWebView` instead of building a new one and the
//     load under test was never issued.
//
// Both are invisible in the file: it reads like a test either way. This
// gate is structural for the same reason the Tor one is — nothing in CI
// compiles or runs the Apple path outside the macOS tier itself, and a tier
// that cannot fail is worse than no tier, because it is counted.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const testRel = 'integration_test/proxy_binding_test.dart';
const fixtureRel = 'integration_test/socks5_fixture.dart';
const source = fs.readFileSync(path.join(repoRoot, testRel), 'utf8');
const fixture = fs.readFileSync(path.join(repoRoot, fixtureRel), 'utf8');

/// Code only: the comments in the file under test name the very things
/// these rules forbid.
const code = source.replace(/^\s*\/\/.*$/gm, '');

test('the fixture origin is not on loopback', () => {
  assert.match(
    code,
    /nonLoopbackIPv4\(\)/,
    `${testRel} must address its origin by a non-loopback interface`,
  );
  const urls = code.match(/'http:\/\/[^']*'/g) ?? [];
  for (const url of urls) {
    assert.doesNotMatch(
      url,
      /127\.0\.0\.1|localhost|\[::1\]/,
      `${testRel} loads ${url}: Apple never proxies a loopback destination, ` +
        'so an assertion about that load says nothing about the binding',
    );
  }
  assert.ok(
    urls.some((u) => u.includes('$originHost')),
    `${testRel} must build its loads from the routable fixture address`,
  );
});

test('a mount that is meant to rebuild the webview gets its own key', () => {
  assert.match(
    code,
    /KeyedSubtree\(\s*\n?\s*key:/,
    `${testRel} must key each mount, or a second pumpWidget updates the ` +
      'existing platform view and never issues the load under test',
  );
  assert.match(
    code,
    /ValueKey\('webview-\$\{generation\+\+\}'\)/,
    `${testRel} must derive that key from a counter, so two mounts in one ` +
      'scenario are two different subtrees',
  );
});

test('the proxied scenarios assert the proxy was used, not that a load failed', () => {
  // A negative assertion is satisfied by every way a load can break, which
  // is how both previous versions of this file passed while no proxy was
  // bound. The fixture SOCKS5 server is what makes a positive one possible.
  // Any assertion over what the fixture proxy was *asked for* counts:
  // `isNotEmpty`, a count, or a match on the target it recorded.
  const positivePattern = /socks\.targets\.(isNotEmpty|length|any\()/g;
  assert.match(
    code,
    positivePattern,
    `${testRel} must assert the fixture proxy was asked for the origin`,
  );
  const negatives = code.match(/isNot\(contains\(/g) ?? [];
  const positives = code.match(positivePattern) ?? [];
  assert.ok(
    positives.length >= negatives.length,
    `${testRel} has ${negatives.length} negative assertions and only ` +
      `${positives.length} positive ones; a load that never happened ` +
      'satisfies every negative',
  );
});

test('the SOCKS5 fixture records what it was asked for before it connects', () => {
  const connectAt = fixture.indexOf('Socket.connect(');
  const recordAt = fixture.indexOf('targets.add(');
  assert.ok(recordAt >= 0, `${fixtureRel} must record CONNECT targets`);
  assert.ok(connectAt >= 0, `${fixtureRel} must relay to the target`);
  assert.ok(
    recordAt < connectAt,
    `${fixtureRel} must record the target before dialling it, or an origin ` +
      'that cannot be reached looks like a proxy that was never used',
  );
});

// `integration_test/proxy_simultaneous_test.dart` asks the one question the
// sibling file confounded: whether two data stores can carry two *different*
// proxies at once. It can only answer that while it has more than one
// fixture to tell apart — with a single fixture, a load arriving at the
// wrong site's proxy is indistinguishable from one that was proxied
// correctly, which is how `crossed=false` came to be read as excluding a
// shared proxy context when both panes had simply gone direct.
const simulRel = 'integration_test/proxy_simultaneous_test.dart';
const simulCode = fs
  .readFileSync(path.join(repoRoot, simulRel), 'utf8')
  .replace(/^\s*\/\/.*$/gm, '');

test('the simultaneity file addresses its origins off loopback', () => {
  assert.match(
    simulCode,
    /nonLoopbackIPv4\(\)/,
    `${simulRel} must address its origins by a non-loopback interface`,
  );
  const urls = simulCode.match(/'http:\/\/[^']*'/g) ?? [];
  assert.ok(urls.length > 0, `${simulRel} must load something`);
  for (const url of urls) {
    assert.doesNotMatch(
      url,
      /127\.0\.0\.1|localhost|\[::1\]/,
      `${simulRel} loads ${url}: Apple never proxies a loopback destination`,
    );
  }
});

test('the simultaneity file keeps more than one proxy to tell apart', () => {
  const fixtureCount = simulCode.match(/const fixtureCount = (\d+)/);
  assert.ok(fixtureCount, `${simulRel} must declare fixtureCount`);
  assert.ok(
    Number(fixtureCount[1]) >= 2,
    `${simulRel} declares fixtureCount=${fixtureCount[1]}; with fewer than ` +
      'two fixtures a load arriving at a sibling site\'s proxy reads as a ' +
      'correctly proxied one and the file measures nothing',
  );
  assert.match(
    simulCode,
    /CROSSED/,
    `${simulRel} must classify a load that reached a sibling's proxy ` +
      'separately from one that reached its own',
  );
  const distinct = new Set(
    (simulCode.match(/const (fixtureOf|lateFixtureOf) = <int>\[[^\]]*\]/g) ?? [])
      .flatMap((decl) => (decl.match(/\d+/g) ?? [])),
  );
  assert.ok(
    distinct.size >= 2,
    `${simulRel} must point its panes at different fixtures; pointing them ` +
      'all at one is the confound this file exists to remove',
  );
});

test('the simultaneity file asserts its panes used their own proxy', () => {
  assert.match(
    simulCode,
    /socks\[f\]\.targets\.contains\(/,
    `${simulRel} must read the verdict off what a fixture proxy was asked ` +
      'for, not off the origin log: the fixture relays, so a proxied load ' +
      'reaches the origin too',
  );
  assert.match(
    simulCode,
    /expect\(\s*own,\s*paneCount,/,
    `${simulRel} must assert every first-frame pane used its own proxy; a ` +
      'reported-only verdict is how this tier spent its life green',
  );
});

test('every simultaneity pane builds under its own key', () => {
  const keys = simulCode.match(/ValueKey\('[^']*\$\{?i\}?'\)/g) ?? [];
  assert.ok(
    keys.length >= 2,
    `${simulRel} must key each pane by its index, or panes at the same ` +
      'position update one platform view and the extra loads are never issued',
  );
  assert.equal(
    new Set(keys).size,
    keys.length,
    `${simulRel} reuses a key between pane groups: ${keys.join(', ')}`,
  );
});
