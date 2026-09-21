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

// `integration_test/proxy_http_connect_test.dart` is the same simultaneity
// question asked of the other delivery route WebKit has for a store's
// proxy. It only means anything while it stays an HTTP CONNECT proxy: a
// SOCKS5 rule takes the live-nw_context path, which is the one under
// suspicion, so rewriting these rules to socks5:// would silently turn the
// file into a duplicate of its sibling.
const httpcRel = 'integration_test/proxy_http_connect_test.dart';
const httpcCode = fs
  .readFileSync(path.join(repoRoot, httpcRel), 'utf8')
  .replace(/^\s*\/\/.*$/gm, '');

test('the HTTP CONNECT file keeps its panes on HTTP CONNECT proxies', () => {
  const firstFrame = httpcCode.slice(
    0,
    httpcCode.indexOf('for the contrast') >= 0
      ? httpcCode.indexOf('for the contrast')
      : httpcCode.length,
  );
  assert.match(
    firstFrame,
    /ProxyRule\(\s*\n?\s*url: 'http:\/\/127\.0\.0\.1:\$\{proxies\[i\]\.port\}'/,
    `${httpcRel} must point its first-frame panes at HTTP CONNECT proxies; ` +
      'a socks5:// rule takes the live-context path and measures nothing new',
  );
  assert.match(
    httpcCode,
    /HttpConnectFixture/,
    `${httpcRel} must use the HTTP CONNECT fixture`,
  );
});

test('the HTTP CONNECT file gives every pane its own proxy and asserts', () => {
  assert.match(
    httpcCode,
    /proxies\[f\]\.targets\.contains\(/,
    `${httpcRel} must read its verdict off what a proxy was asked for`,
  );
  assert.match(
    httpcCode,
    /CROSSED/,
    `${httpcRel} must tell a load that reached a sibling's proxy apart ` +
      'from one that reached its own',
  );
  assert.match(
    httpcCode,
    /expect\(\s*own,\s*paneCount,/,
    `${httpcRel} must assert, not just report`,
  );
  const paneCount = httpcCode.match(/const paneCount = (\d+)/);
  assert.ok(paneCount && Number(paneCount[1]) >= 2, `${httpcRel} needs >= 2 panes`);
  assert.match(
    httpcCode,
    /proxies\.add\(await HttpConnectFixture\.bind\(\)\)/,
    `${httpcRel} must bind one proxy per pane, or the panes cannot be ` +
      'distinguished from each other',
  );
});

// A file that reads PlatformInfo.isProxySupported without awaiting
// PlatformInfo.initialize() gets false, skips every scenario, and reports
// green having measured nothing -- which is exactly what the first run of
// proxy_simultaneous and proxy_http_connect did. The tier prints a skip and
// a pass identically, so nothing downstream catches it.
test('every Apple proxy tier initializes PlatformInfo before reading it', () => {
  const files = [
    'integration_test/proxy_binding_test.dart',
    'integration_test/proxy_window_test.dart',
    'integration_test/proxy_simultaneous_test.dart',
    'integration_test/proxy_http_connect_test.dart',
    'integration_test/proxy_relay_binding_test.dart',
    'integration_test/proxy_rate_test.dart',
    'integration_test/proxy_connect_https_test.dart',
    'integration_test/proxy_shape_test.dart',
  ];
  for (const rel of files) {
    const body = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    if (!/PlatformInfo\.isProxySupported/.test(body)) continue;
    assert.match(
      body,
      /await PlatformInfo\.initialize\(\)/,
      `${rel} reads PlatformInfo.isProxySupported but never awaits ` +
        'PlatformInfo.initialize(); it would skip every scenario and pass',
    );
    const initAt = body.indexOf('await PlatformInfo.initialize()');
    const readAt = body.indexOf('PlatformInfo.isProxySupported');
    assert.ok(
      initAt < readAt,
      `${rel} reads PlatformInfo.isProxySupported before initializing it`,
    );
  }
});

// The floor check must fail rather than skip on an Apple tier. A skip is
// indistinguishable from a run in the tier output, so the two files that
// skipped on it were only caught by reading their verdict lines by hand.
test('the simultaneity files assert the proxy floor instead of skipping it', () => {
  for (const rel of [
    'integration_test/proxy_simultaneous_test.dart',
    'integration_test/proxy_http_connect_test.dart',
  ]) {
    const body = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    assert.doesNotMatch(
      body,
      /markTestSkipped\([^)]*floor/,
      `${rel} skips on the proxyConfigurations floor; on these tiers that ` +
        'means PlatformInfo was not initialized, so it must fail instead',
    );
    assert.match(
      body,
      /expect\(\s*\n?\s*PlatformInfo\.isProxySupported,\s*\n?\s*isTrue,/,
      `${rel} must assert proxy support is available`,
    );
  }
});

// Both https arms skipped on the macOS tier with "openssl is not installed":
// that tier runs a built app bundle, where `Process.runSync` has no shell and
// no PATH to find one on. The arm the whole investigation turns on therefore
// never executed, and printed nothing at all -- a skip and a run look the
// same from outside. The certificate is minted in Dart now, and no tier may
// go back to gating a TLS origin on a binary being installed.
test('no proxy tier serves TLS by shelling out to a binary', () => {
  const dirs = ['integration_test', 'test'];
  for (const dir of dirs) {
    for (const name of fs.readdirSync(path.join(repoRoot, dir))) {
      if (!name.endsWith('.dart')) continue;
      const rel = `${dir}/${name}`;
      const body = fs
        .readFileSync(path.join(repoRoot, rel), 'utf8')
        .replace(/^\s*\/\/.*$/gm, '');
      assert.doesNotMatch(
        body,
        /Process\.(run|runSync|start)\(\s*\n?\s*'openssl'/,
        `${rel} shells out to openssl; the macOS integration tier has no ` +
          'such binary, so the file would skip and report green having ' +
          'measured nothing. Use generateSelfSignedCert instead',
      );
    }
  }
});

test('the https proxy arms mint their own certificate and serve it', () => {
  for (const rel of [
    'integration_test/proxy_connect_https_test.dart',
    'integration_test/proxy_relay_binding_test.dart',
  ]) {
    const body = fs
      .readFileSync(path.join(repoRoot, rel), 'utf8')
      .replace(/^\s*\/\/.*$/gm, '');
    assert.match(
      body,
      /generateSelfSignedCert\(/,
      `${rel} must mint its certificate in Dart`,
    );
    assert.match(
      body,
      /HttpServer\.bindSecure\(/,
      `${rel} exists to put TLS on the destination; a plaintext origin is ` +
        'the arm it was written to replace',
    );
    const urls = body.match(/'https:\/\/[^']*'/g) ?? [];
    assert.ok(
      urls.length > 0 && urls.every((u) => u.includes('$originHost')),
      `${rel} must load https origins built from the routable address, got ` +
        `[${urls.join(' ')}]`,
    );
    assert.doesNotMatch(
      body,
      /markTestSkipped\([^)]*openssl/,
      `${rel} still skips on openssl`,
    );
  }
});

// The general rule behind three of the specific gates above, and the one
// BUG-014 gap 5 said was enforced nowhere: an effect-level assertion needs a
// control that fails when the instrument is broken. Run 3097 produced a whole
// app process that proxied nothing at all, including its first frame, while a
// different process in the same run proxied its first-frame pair. Against a
// process in that state "no pane reached its proxy" measures the process, and
// is indistinguishable from the finding it would be reported as.
//
// So every arm whose verdict can be a null result carries a positive control:
// a pane in the same process, on the arrangement that has bound a proxy in
// every run it was measured in (SOCKS5, first frame), asserted before the
// arm's own result is believed.
test('every proxy arm that can read null carries a positive control', () => {
  const arms = [
    'integration_test/proxy_rate_test.dart',
    'integration_test/proxy_connect_https_test.dart',
    'integration_test/proxy_relay_binding_test.dart',
  ];
  for (const rel of arms) {
    const body = fs
      .readFileSync(path.join(repoRoot, rel), 'utf8')
      .replace(/^\s*\/\/.*$/gm, '');
    assert.match(
      body,
      /socks5:\/\/127\.0\.0\.1:\$\{controlSocks\.port\}|containerId: 'ws-proxy-rate-control'/,
      `${rel} has no SOCKS control pane; a null verdict from it cannot be ` +
        'told apart from a process that proxied nothing',
    );
    assert.match(
      body,
      /expect\(\s*\n?\s*control,\s*\n?\s*'proxied',/,
      `${rel} does not assert its control, so a dead process still reports ` +
        'a verdict that reads like a finding',
    );
    assert.match(
      body,
      /control(-|=)/,
      `${rel} must carry the control into its verdict line`,
    );
  }
});

// A verdict read from a count of proxy connections cannot see a request that
// was served over one already open (BUG-014 attempt 87).
//
// Once an arm sends its second load back to the origin that was just proxied
// -- which is what holds session-wrapper routing fixed -- HTTP/1.1 keep-alive
// means the proxy is asked for no new CONNECT. "No new CONNECT" is then what a
// WORKING proxy produces, identical to a bypass. The readable form attributes
// each request: the fixture records the local port of every upstream socket it
// dials, the origin records the peer port of every request it serves, and the
// two are matched.
test('both proxy fixtures expose the ports they relayed from', () => {
  for (const rel of [
    'integration_test/socks5_fixture.dart',
    'integration_test/http_connect_fixture.dart',
  ]) {
    const body = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    assert.match(
      body,
      /final relayedPorts = <int>\{\};/,
      `${rel} must expose relayedPorts, or an arm has nothing to attribute ` +
        'a request against',
    );
    assert.match(
      body,
      /relayedPorts\.add\(upstream\.port\);/,
      `${rel} declares relayedPorts without recording the upstream socket it ` +
        'dialled, so the set is always empty and every request reads direct',
    );
  }
});

test('an arm that reloads one origin attributes requests, not connections', () => {
  const arms = [
    'integration_test/proxy_timing_test.dart',
    'integration_test/proxy_urlsession_test.dart',
    'integration_test/proxy_persession_test.dart',
  ];
  for (const rel of arms) {
    const body = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    const armCode = body.replace(/^\s*\/\/.*$/gm, '');
    assert.match(
      armCode,
      /connectionInfo\?\.remotePort/,
      `${rel} loads one origin more than once, so its origin must record the ` +
        'peer each request arrived from',
    );
    assert.match(
      armCode,
      /relayedPorts/,
      `${rel} must reach its verdict through the fixture's relayed ports; ` +
        'anything else cannot tell a reused connection from a bypass',
    );
    for (const line of armCode.split('\n')) {
      assert.doesNotMatch(
        line,
        /targets\b.*\.length\s*[<>]/,
        `${rel} compares a count of CONNECTs to reach a verdict: ${line.trim()}`,
      );
    }
  }
});
