// Structural gate: a Dart-side fetch whose URL page script can choose is
// judged on the address it will connect to (BUG-012).
//
// The guard has been partial three times, each time because a new path opted
// out silently rather than because the check was wrong: a redirect the client
// followed past it, a name the resolver expanded past it, and a second call
// site that copied the range table and not the rest. Nothing failed; the
// requests just landed on the LAN.
//
// So this gate does not test the guard. It tests that every outbound seam has
// been classified: either it routes page-chosen URLs through
// `classifyOutboundTarget`, or it is listed here with the reason it does not
// need to. A new `outboundHttp.clientFor` in neither list fails, which puts
// the decision in front of whoever adds it.
//
// Cross-links:
//   docs/bugs/012-page-steered-outbound-reach.md
//   openspec/specs/user-scripts/spec.md                 US-006
//   openspec/changes/page-reachable-bridge-hardening/   US-DR-007

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SEAM = 'outboundHttp.clientFor';
const GATE = 'classifyOutboundTarget';

// Seams that take a URL a loaded page chose. Each MUST call the gate.
const GUARDED = [
  'lib/services/user_script_service.dart',
  'lib/services/media_session_service.dart',
];

// Seams that do not, and why. A reason is required: "it seemed fine" is how
// the artwork fetch ended up with half the guard for a fortnight.
const EXEMPT = {
  'lib/main.dart':
    'getPageTitle takes a URL the user is adding as a site or one arriving in '
    + 'a share intent. Attacker-authored, but not chosen by a loaded page, so '
    + 'it is a different surface from this class.',
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
  'lib/services/download_engine.dart':
    'The URL is page-supplied, but a download is user-confirmed and lands in '
    + 'a file rather than back in the page. Not audited against this '
    + 'invariant — see the enumeration gap in docs/bugs/012.',
  'lib/services/icon_service.dart':
    'Favicon URLs are derived from page markup. Not audited against this '
    + 'invariant — see the enumeration gap in docs/bugs/012.',
  'lib/third_party/favicon/favicon.dart':
    'Vendored favicon resolution, reached from icon_service; same gap.',
};

function dartFiles(dir, out = []) {
  for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.posix.join(dir, entry.name);
    if (entry.isDirectory()) dartFiles(rel, out);
    else if (entry.name.endsWith('.dart')) out.push(rel);
  }
  return out;
}

const seams = dartFiles('lib').filter((f) =>
  fs.readFileSync(path.join(ROOT, f), 'utf8').includes(SEAM));

test('every outbound seam is classified', () => {
  const classified = new Set([...GUARDED, ...Object.keys(EXEMPT)]);
  const unclassified = seams.filter((f) => !classified.has(f));
  assert.deepEqual(unclassified, [],
    'a new Dart-side fetch: if page script can choose its URL, call '
    + `${GATE}; if it cannot, add it to EXEMPT with the reason`);
});

test('every classified seam still makes an outbound call', () => {
  // A stale entry is worse than none: it reads as a decision that was made.
  const stale = [...GUARDED, ...Object.keys(EXEMPT)].filter((f) => !seams.includes(f));
  assert.deepEqual(stale, [], `no longer calls ${SEAM} — drop the entry`);
});

for (const file of GUARDED) {
  test(`${file} judges the destination, not the URL string`, () => {
    const src = fs.readFileSync(path.join(ROOT, file), 'utf8');
    assert.ok(src.includes(GATE),
      `${file} takes a page-chosen URL, so it must resolve it before it `
      + `connects. Removing the ${GATE} call reopens BUG-012 on this path.`);
  });
}

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
    fs.readFileSync(path.join(ROOT, f), 'utf8').includes(marker));
  assert.deepEqual(homes, ['lib/services/host_resolution.dart'],
    'do not copy the range table — import isPrivateOrLoopbackHost');
});
