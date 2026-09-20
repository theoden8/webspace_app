// The per-site proxy gate has to be able to fail (LEAK-003, BUG-014).
//
// `integration_test/proxy_binding_test.dart` is the only tier that observes
// whether a proxy reached the engine, and it has reported a verdict through
// two separate reasons why it could not have observed anything:
//
//  1. Its origin was on `127.0.0.1`. Apple never sends a loopback
//     destination through a proxy, so an assertion about where that load
//     went was decided before the binding was.
//  2. Its second mount reused the same widget position, so Flutter updated
//     the existing `InAppWebView` instead of building a new one and the
//     load under test was never issued.
//
// Both are invisible in the file: it reads like a test either way. Both
// were found and fixed once (BUG-014 attempt 4) and came back when the
// branch was trimmed, together with this gate. Structural for the same
// reason the Tor one is: nothing in CI runs the Apple path outside the
// macOS tier itself, and a tier that cannot fail is worse than no tier,
// because it is counted.

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
  assert.ok(urls.length > 0, `${testRel} must load something`);
  for (const url of urls) {
    assert.doesNotMatch(
      url,
      /127\.0\.0\.1|localhost|\[::1\]/,
      `${testRel} loads ${url}: Apple never proxies a loopback destination, ` +
        'so an assertion about that load says nothing about the binding',
    );
  }
  assert.ok(
    urls.every((u) => u.includes('$originHost')),
    `${testRel} must build every load from the routable fixture address, ` +
      `got [${urls.join(' ')}]`,
  );
});

test('the origin server answers on the routable address', () => {
  // `loopbackIPv4` as a bind address serves only 127.0.0.1, so a load
  // addressed to the routable interface is refused and the arm fails for a
  // reason that has nothing to do with the proxy.
  assert.doesNotMatch(
    code,
    /HttpServer\.bind\(\s*\n?\s*InternetAddress\.loopbackIPv4/,
    `${testRel} binds its origin to loopback only; the routable address it ` +
      'loads from will not be answered',
  );
  assert.match(
    code,
    /HttpServer\.bind\(\s*\n?\s*InternetAddress\.anyIPv4/,
    `${testRel} must bind its origin on anyIPv4`,
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
    /ValueKey\('[^']*\$/,
    `${testRel} must interpolate that key, so two mounts are two subtrees`,
  );
  const siteIds = [...code.matchAll(/siteId:\s*'([^']+)'/g)].map((m) => m[1]);
  assert.ok(siteIds.length >= 2, `${testRel} must mount more than once`);
  assert.equal(
    new Set(siteIds).size,
    siteIds.length,
    `${testRel} reuses a siteId between mounts (${siteIds.join(', ')}); the ` +
      'key is derived from it, so the second mount would reuse the first ' +
      "mount's platform view",
  );
});

test('the proxied scenario asserts the proxy was used, not that a load failed', () => {
  // A negative assertion is satisfied by every way a load can break, which
  // is how previous versions of this file reported a verdict while no proxy
  // was bound. The fixture SOCKS5 server is what makes a positive one
  // possible: it records the CONNECT it was asked for.
  //
  // Read off the proxied arm's own body rather than counted over the file:
  // the control legitimately asserts a negative, and a count lets the
  // arm that matters trade its positive away for the control's.
  const arms = code.split(/testWidgets\(/).slice(1);
  const proxied = arms.find((a) => /must arrive at the proxy/.test(a));
  assert.ok(
    proxied,
    `${testRel} must have an arm that waits for the proxy to be asked`,
  );
  assert.match(
    proxied,
    /expect\(\s*\n?\s*socks\.targets,\s*\n?\s*contains\(/,
    `${testRel}'s proxied arm must assert the fixture proxy was asked for ` +
      'the origin; anything else it can assert is satisfied by a load that ' +
      'never happened',
  );
  assert.doesNotMatch(
    proxied,
    /isNot\(/,
    `${testRel}'s proxied arm asserts a negative; every way this file has ` +
      'been wrong so far broke the load, which satisfies one',
  );
});

test('the tier measures a site switch, not only the first proxied load', () => {
  // A session's first proxied load is the arrangement most likely to bind.
  // PROXY-008 flips the override on every activation, so the case that
  // leaks is the second store under a new proxy -- and it is invisible if
  // the file only ever measures the first.
  const arms = code.split(/testWidgets\(/).slice(1);
  const switched = arms.find((a) => /must arrive at the new proxy/.test(a));
  assert.ok(
    switched,
    `${testRel} must carry an arm that switches a second site to a ` +
      'different proxy while the first store is alive',
  );
  assert.match(
    switched,
    /expect\(\s*\n?\s*altSocks\.targets,\s*\n?\s*contains\(/,
    `${testRel}'s switch arm must assert the NEW proxy was asked for the ` +
      'origin',
  );
  assert.match(
    switched,
    /expect\(\s*\n?\s*socks\.targets,\s*\n?\s*isNot\(contains\(/,
    `${testRel}'s switch arm must also rule out the first proxy: a load ` +
      "leaving through the previous site's circuit is worse than an " +
      'unproxied one, and one fixture cannot tell the two apart',
  );
  assert.ok(
    /Socks5Fixture\.bind\(\)[\s\S]*Socks5Fixture\.bind\(\)/.test(code),
    `${testRel} must bind two proxy fixtures, or "went through the new ` +
      'proxy" and "still on the old one" are the same observation',
  );
});

test('the file refuses to report a verdict with no routable address', () => {
  // Falling back to loopback silently would restore the exact confound
  // above on any host without a second interface.
  assert.match(
    code,
    /markTestSkipped\([^)]*loopback/,
    `${testRel} must skip rather than measure when nonLoopbackIPv4() finds ` +
      'nothing; a loopback origin cannot tell a bound proxy from a dropped one',
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

// A file that reads PlatformInfo.isProxySupported without awaiting
// PlatformInfo.initialize() gets false, skips every scenario, and reports
// green having measured nothing. The tier prints a skip and a pass
// identically, so nothing downstream catches it.
test('the Apple proxy tier initializes PlatformInfo before reading it', () => {
  assert.match(
    source,
    /await PlatformInfo\.initialize\(\)/,
    `${testRel} reads PlatformInfo.isProxySupported but never awaits ` +
      'PlatformInfo.initialize(); it would skip every scenario and pass',
  );
  assert.ok(
    source.indexOf('await PlatformInfo.initialize()') <
      source.indexOf('PlatformInfo.isProxySupported'),
    `${testRel} reads PlatformInfo.isProxySupported before initializing it`,
  );
});

// The container store is the one the app binds for a site. Measuring
// `WKWebsiteDataStore.default()` instead answers a question about a store
// shape no site uses.
test('the tier binds a container, the way the app does', () => {
  assert.match(
    code,
    /await ContainerNative\.instance\.isSupported\(\)/,
    `${testRel} must resolve container support before mounting, or ` +
      'cachedSupported is false, no containerId is sent, and the fork falls ' +
      'through to the default store',
  );
});
