// Structural gate: a Dart-side fetch whose URL page script can choose connects
// only to an address the guard judged (BUG-012, SEC-049).
//
// The guard was partial five times, each because a new path opted out silently
// rather than because the check was wrong: a redirect the client followed past
// it, a name the resolver expanded past it, a second call site that copied the
// range table and not the rest, a pre-flight check the client then re-resolved
// past (the rebind), and auto-following fetchers whose client saw only the first
// hop under a proxy. SEC-049 moved the decision to the connection and BUG-012's
// closer moved redirect following to one place: `followPageSteered` is the one
// function that follows a page-steered redirect, each hop a fresh request through
// the guarded connect with the client's own following OFF, so every hop is
// judged on every route. Its client (a `PageSteeredHttp`) is reachable nowhere
// else — the field is library-private — so a page-steered fetch cannot sidestep
// it. A page-steered client is also built in only one place, `buildPageSteeredClient`,
// which the public re-export hides, so no caller reached through `outbound_http.dart`
// can even name the build (SEC-049). The one path the compiler cannot close is a
// direct `import` of the platform half `outbound_http_io.dart`, which this gate
// polices: only the seam library names `buildPageSteeredClient`.
//
// So this gate does not test the guard. It tests that every outbound seam has
// been classified: either it routes page-chosen URLs through `followPageSteered`,
// or it is listed here with the reason it does not need to. A new
// `outboundHttp.clientFor`, `fetchViaAppProxy`, `pageSteeredClient`,
// `buildPageSteeredClient` or `followPageSteered` caller in neither list fails,
// which puts the decision in front of whoever adds it.
//
// Cross-links:
//   docs/bugs/012-page-steered-outbound-reach.md
//   openspec/specs/ip-leakage/spec.md                   LEAK-002
//   openspec/specs/user-scripts/spec.md                 US-006, US-DR-007

const test = require('node:test');
const assert = require('node:assert');
const { read, dartFiles } = require('./helpers/source');

const SEAMS = [
  'outboundHttp.clientFor',
  'fetchViaAppProxy(',
  'pageSteeredClient(',
  'buildPageSteeredClient(',
  'followPageSteered(',
];
const GATE = 'followPageSteered(';

// The raw client-producing seams. A GUARDED fetcher may not name any of them:
// each hands out a usable client that would sidestep the follower —
// `buildPageSteeredClient` builds a page-steered client with a public `.client`
// (reachable only by a direct platform import, since the re-export hides it),
// `clientFor` an unguarded one. A fetcher gets its client only by handing a
// route to `followPageSteered`.
const RAW_SEAMS = [
  'outboundHttp.clientFor',
  'buildPageSteeredClient(',
  'fetchViaAppProxy(',
];

// Seams that take a URL a loaded page chose. Each MUST route through
// `followPageSteered`, which judges every hop (the URL and each redirect) as it
// connects and connects only to the judged address, on every route (SEC-049,
// BUG-012). No fetcher follows a redirect itself (the `no fetcher follows a
// page-steered redirect by hand` probe below), and none can reach the client to
// try (the `only the follower consumes` probe).
const GUARDED = [
  'lib/services/user_script_service.dart',
  'lib/services/media_session_service.dart',
  'lib/services/icon_service.dart',
  'lib/third_party/favicon/favicon.dart',
];

// Seams that do not, and why. A reason is required: "it seemed fine" is how
// the artwork fetch ended up with half the guard for a fortnight.
const EXEMPT = {
  'lib/screens/location_picker.dart':
    'OSM tile fetches against a fixed host.',
  'lib/services/clearurl_service.dart':
    'The ClearURLs rules URL is app-configured, not page-supplied.',
  'lib/services/content_blocker_service.dart':
    'Filter-list URLs come from app configuration or a list the user added.',
  'lib/services/dns_block_service.dart':
    'Hagezi mirrors, fixed in the app.',
  'lib/services/firefox_user_agent_service.dart':
    'A pinned upstream URL.',
  'lib/services/localcdn_service.dart':
    'The LocalCDN bundle, fixed in the app.',
  'lib/services/timezone_location_service.dart':
    'A fixed timezone API endpoint.',
  'lib/services/top_sites_service.dart':
    'One fixed URL, the CrUX top list (SUGGEST-008), fetched only from its App Settings button.',
  'lib/services/site_search_list_service.dart':
    'One fixed URL, Kagi\'s bang list (LIR-036), fetched only from its App Settings button.',
  'lib/services/tor_geoip_io.dart':
    'tor\'s GeoIP table from the Tor Project URLs fixed in kTorGeoIpUrls, '
    + 'through Tor.',
  'lib/services/web_extension_library.dart':
    'Release and search queries go to addons.mozilla.org and api.github.com, '
    + 'built from a link the user pasted or typed (WEBEXT-017, WEBEXT-019); '
    + 'a package is downloaded from the https URL those APIs answer with. No '
    + 'loaded page chooses any of them.',
  'lib/services/outbound_http.dart':
    'The seam definitions themselves: fetchViaAppProxy for the downloads the '
    + 'app configures, pageSteeredClient (wraps the hidden build, consumed only '
    + 'by followPageSteered) and followPageSteered, the one follower every '
    + 'GUARDED file routes through. Each caller is classified here on its own.',
  'lib/services/outbound_http_io.dart':
    'The dart:io seam: buildPageSteeredClient (hidden from the re-export), the '
    + 'connection pin and the literal guard. Named only here and in '
    + 'outbound_http.dart.',
  'lib/services/outbound_http_web.dart':
    'The web seam: buildPageSteeredClient defers to the browser, which enforces '
    + 'private-network access itself.',
  'lib/services/proxy_test_service.dart':
    'The probe target is the site\'s own home URL (typed by the user, not '
    + 'chosen by a loaded page) or the fixed example.com fallback, and '
    + 'proxyTestTarget already rejects a private or loopback literal so the '
    + 'test cannot be pointed at the LAN.',
  'lib/services/download_engine.dart':
    'The URL is page-supplied, but a download is user-confirmed and lands in '
    + 'a file rather than back in the page, so it is a different surface from a '
    + 'page-rendered fetch (see docs/bugs/012).',
};

const seams = dartFiles('lib').filter((f) =>
  SEAMS.some((seam) => read(f).includes(seam)));

test('every outbound seam is classified', () => {
  const classified = new Set([...GUARDED, ...Object.keys(EXEMPT)]);
  const unclassified = seams.filter((f) => !classified.has(f));
  assert.deepEqual(unclassified, [],
    'a new Dart-side fetch: if page script can choose its URL, route it through '
    + `${GATE.slice(0, -1)}; if it cannot, add it to EXEMPT with the reason`);
});

test('every classified seam still makes an outbound call', () => {
  // A stale entry is worse than none: it reads as a decision that was made.
  const stale = [...GUARDED, ...Object.keys(EXEMPT)].filter((f) => !seams.includes(f));
  assert.deepEqual(stale, [], `no longer calls ${SEAMS.join(' or ')} — drop the entry`);
});

for (const file of GUARDED) {
  test(`${file} routes page-chosen URLs through the page-steered client`, () => {
    const src = read(file);
    assert.ok(src.includes(GATE),
      `${file} takes a page-chosen URL, so it must connect through `
      + `${GATE.slice(0, -1)}, which judges the destination as it connects. `
      + `Dropping it reopens BUG-012 on this path.`);
  });
}

// A PageSteeredHttp's client field is library-private, so the follower is the
// only code that can read it: once a page-steered client is built, nothing but
// followPageSteered can drive it. This holds the structure behind that — the
// wrapper is built in exactly one file, the follower's own. Plant a
// `pageSteeredClient(...)` in a fetcher and this fires.
test('only the follower consumes the page-steered client', () => {
  const callers = dartFiles('lib').filter((f) =>
    read(f).includes('pageSteeredClient('));
  assert.deepEqual(callers, ['lib/services/outbound_http.dart'],
    'a PageSteeredHttp is consumed only by followPageSteered (its client field '
    + 'is library-private). Route a new page-steered fetch through '
    + 'followPageSteered, never pageSteeredClient directly.');
});

// The per-file "routes through" check above only sees that followPageSteered
// appears somewhere in the file; a GUARDED fetcher could still reach a raw
// client-producing seam beside it. So none may name one. Plant
// `outboundHttp.clientFor(r).client.get(u)` (or a direct-imported
// `buildPageSteeredClient(...)`) in a GUARDED file and this fires.
test('no fetcher reaches a raw client-producing seam', () => {
  for (const file of GUARDED) {
    const src = read(file);
    for (const seam of RAW_SEAMS) {
      assert.ok(!src.includes(seam),
        `${file} names ${seam}, a raw client seam that sidesteps the follower. `
        + `A page-chosen URL gets its client only from followPageSteered(route, ...).`);
    }
  }
});

// buildPageSteeredClient builds a page-steered client with a public `.client`.
// The public re-export hides it, so no caller reached through outbound_http.dart
// can name it (a plant there does not compile); the one path the compiler cannot
// close is a direct import of the platform half. Confine the name to the seam:
// plant a direct `import '.../outbound_http_io.dart'` + `buildPageSteeredClient(r)`
// anywhere else and this fires.
test('only the seam library names the page-steered build', () => {
  const callers = dartFiles('lib')
    .filter((f) => read(f).includes('buildPageSteeredClient('))
    .sort();
  assert.deepEqual(callers, [
    'lib/services/outbound_http.dart',
    'lib/services/outbound_http_io.dart',
    'lib/services/outbound_http_web.dart',
  ], 'buildPageSteeredClient builds a page-steered client; name it only inside the '
    + 'outbound_http seam, and consume the result only through followPageSteered.');
});

// Plant a `followRedirects` or a `headers['location']` loop in a GUARDED fetcher
// and this fires: the one follower follows the redirect, each hop through the
// guarded connect, so a fetcher that re-grows a loop reopens BUG-012.
test('no fetcher follows a page-steered redirect by hand', () => {
  for (const file of GUARDED) {
    const src = read(file);
    assert.ok(!src.includes('followRedirects'),
      `${file} sets followRedirects, so it follows a redirect itself. The one `
      + `follower (followPageSteered) does that, with the client's own following `
      + `off on every hop (BUG-012).`);
    assert.ok(!/headers\[['"]location['"]\]/.test(src),
      `${file} reads the Location header, so it follows a redirect itself. Route `
      + `it through followPageSteered instead (BUG-012).`);
  }
});

test('every exemption states a reason', () => {
  for (const [file, why] of Object.entries(EXEMPT)) {
    assert.ok(why && why.trim().length > 20, `${file}: give an actual reason`);
  }
});

// The range table was copied into a second file once already, and the copy is
// what let the artwork fetch ship with half the guard. One home, so a fix
// reaches every caller.
test('the private-range table lives in exactly one file', () => {
  const marker = 'a == 169 && b == 254';
  const homes = dartFiles('lib').filter((f) =>
    read(f).includes(marker));
  assert.deepEqual(homes, ['lib/services/host_resolution.dart'],
    'do not copy the range table — import isPrivateOrLoopbackHost');
});
