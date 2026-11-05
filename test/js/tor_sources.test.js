// Every tor the Linux packages ship is built by linux/tor.cmake from a pinned
// source that stays where the pin names it, and never as tor's GPL build.
// dist.torproject.org keeps only current releases, so a pin there stops
// resolving once the Tor Project moves on; its archive keeps every one.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const ARCHIVE = 'https://archive.torproject.org/tor-package-archive/';

test("the Linux build's tor source is in the Tor Project's archive, at a SHA-256 (TOR-027)", () => {
  const rel = 'linux/tor.cmake';
  const src = read(rel);
  assert.match(src, /^set\(TOR_VERSION "\d+(\.\d+)+"\)$/m, `${rel} pins no tor version`);
  assert.match(src, /^set\(TOR_SOURCE_SHA256\n {2}"[0-9a-f]{64}"\)$/m, `${rel} pins no SHA-256`);
  assert.match(src, /^ {4}URL_HASH SHA256=\$\{TOR_SOURCE_SHA256\}$/m,
    `${rel} does not hold the source to its SHA-256`);
  const urls = [...src.matchAll(/"(https:\/\/[^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(urls, [`${ARCHIVE}tor-\${TOR_VERSION}.tar.gz`],
    `${rel} downloads from somewhere other than ${ARCHIVE}, which keeps every release`);
});

// tor's configure builds its proof-of-work module, and with it a GPL
// program, only when asked; scripts/verify_tor_shipped.sh refuses the built
// result on CI, and this refuses the ask before anything builds.
test('tor is never configured as its GPL build (LICENSE-001)', () => {
  const rel = 'linux/tor_build.sh';
  const code = read(rel).split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  assert.match(code, /^\.\/configure \\$/m, `${rel} no longer runs tor's configure`);
  assert.doesNotMatch(code, /--enable-gpl/, `${rel} configures tor with --enable-gpl`);
  assert.doesNotMatch(code, /pluggable_transports/,
    `${rel} lays out a transport; lyrebird is go/iptproxy/build.sh's alone`);
});

/** Comment-free lines of [text]. */
const code = (text) => text.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

/** The body of CMake function [name] in [text], or ''. */
function cmakeFunction(text, name) {
  const start = text.indexOf(`\nfunction(${name} `);
  if (start < 0) return '';
  return text.slice(start, text.indexOf('\nendfunction()', start));
}

/**
 * What keeps the bundle's lyrebird the one go/iptproxy/build.sh builds and
 * checks, beside the tor it runs for, one line each.
 */
function lyrebirdProblems({ cmake, lists, verify, workflow }) {
  const out = [];
  // Where the debug and release trees both look, so the second finds it
  // current: the integration bundle builds after the egress guard is armed.
  if (!/^webspace_build_tor\("\$\{WEBSPACE_TOR_ARCH\}"\n {2}"[^"\n]+"\n {2}"\$\{CMAKE_CURRENT_SOURCE_DIR\}\/\.\.\/build\/lyrebird"\n/m.test(lists)) {
    out.push('the debug and release trees build lyrebird apart');
  }
  const tor = cmakeFunction(cmake, 'webspace_build_tor');
  const own = cmakeFunction(cmake, '_webspace_build_lyrebird');
  const call = tor.indexOf('_webspace_build_lyrebird("${LYREBIRD_DIR}" "${TOR_INSTALL_DIR}")');
  // After every return, so a build without tor (none, another architecture)
  // builds no lyrebird either.
  if (call < 0 || call < tor.lastIndexOf('return()')) out.push('lyrebird is not built where tor is');
  if (!/^set\(_WEBSPACE_IPTPROXY_BUILD "\$\{CMAKE_CURRENT_LIST_DIR\}\/\.\.\/go\/iptproxy\/build\.sh"\)$/m.test(cmake)) {
    out.push('lyrebird is not go/iptproxy/build.sh\'s');
  }
  if (!/exec sh \\"\$1\\" lyrebird \\"\$2\\""\n\s+"\$\{go_dir\}" "\$\{_WEBSPACE_IPTPROXY_BUILD\}" "\$\{out\}"/.test(own)) {
    out.push('tor.cmake does not run build.sh lyrebird');
  }
  if (!/install\(DIRECTORY "\$\{out\}\/"\n\s+DESTINATION "\$\{TOR_INSTALL_DIR\}"/.test(own)) {
    out.push('lyrebird is not installed beside tor');
  }
  if (!/if\("\$ENV\{WEBSPACE_LYREBIRD\}" STREQUAL "none"\)\n {4}message\([^\n]*\n {4}return\(\)\n {2}endif\(\)/.test(own)) {
    out.push('WEBSPACE_LYREBIRD=none still builds lyrebird');
  }
  if (!/if\(NOT WEBSPACE_GO\)\n(?: {4}[^\n]*\n)*? {4}return\(\)\n {2}endif\(\)/.test(own)) {
    out.push('a build with no go fails instead of building without');
  }
  if (/IPTPROXY_WORK/.test(own)) out.push('lyrebird is built outside the work tree build.sh check reads interop/ against');

  const held = code(verify);
  if (!/if \[ "\$\{WEBSPACE_LYREBIRD:-\}" = none \]; then/.test(held)) {
    out.push('verify_tor_shipped.sh does not check a bundle built without lyrebird as one');
  }
  if (!/\[ ! -x "\$transports\/lyrebird" \]/.test(held)) out.push('verify_tor_shipped.sh does not require lyrebird');
  if (!/sh "\$root\/go\/iptproxy\/build\.sh" check-lyrebird "\$dir"/.test(held)) {
    out.push('verify_tor_shipped.sh does not hold lyrebird to build.sh check-lyrebird');
  }
  if (!/! -path "\$transports\/lyrebird"/.test(held)) out.push('verify_tor_shipped.sh lets another transport ship');

  // The Build Linux job: a go command before the build, and the bridge the
  // real-tor tier reaches through the bundle's lyrebird.
  const job = workflow.slice(workflow.indexOf('\n  build-linux:\n'));
  const end = job.indexOf('\n  build-', 2);
  const body = end < 0 ? job : job.slice(0, end);
  const go = body.indexOf('go-version-file: go/iptproxy/.go-version');
  if (go < 0 || go > body.indexOf('fvm flutter build linux')) out.push('the Linux build has no go before it builds');
  const step = body.slice(body.indexOf('- name: Bundled tor runs'));
  if (!/apt-get install -y --no-install-recommends tor lyrebird\n/.test(step)) {
    out.push('the real-tor tier has no bridge of the machine\'s to reach');
  }
  const kept = step.indexOf("printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d\n");
  if (kept < 0 || kept > step.indexOf('apt-get install')) {
    out.push('the bridge\'s tor package starts a tor service that reaches the network');
  }
  if (!/WS_TOR_BESIDE: build\/linux\/x64\/release\/bundle\/webspace_app\n/.test(step)) {
    out.push('the real-tor tier does not run the bundle\'s tor and lyrebird');
  }
  return out;
}

const shipped = {
  cmake: read('linux/tor.cmake'),
  lists: read('linux/CMakeLists.txt'),
  verify: read('scripts/verify_tor_shipped.sh'),
  workflow: read('.github/workflows/build-and-test.yml'),
};

// The Linux bundle's transports (TOR-016): lyrebird, built from the tree
// go/iptproxy/build.sh patches for Apple, at its pins, with no GPL in it
// (LICENSE-001), beside the tor it runs for, and checked as shipped.
test("the Linux bundle's lyrebird is go/iptproxy/build.sh's, beside its tor (TOR-016, LICENSE-001)", () => {
  assert.deepEqual(lyrebirdProblems(shipped), []);
});

test('each lyrebird rule catches the mistake it is for', () => {
  const swap = (text, from, to) => {
    assert.ok(text.includes(from), `the planted mistake no longer applies: ${from}`);
    return text.replace(from, to);
  };
  const caught = (part, from, to, what) => assert.ok(
    lyrebirdProblems({ ...shipped, [part]: swap(shipped[part], from, to) }).length > 0, `${what} went uncaught`);
  const { cmake } = shipped;
  const tor = cmakeFunction(cmake, 'webspace_build_tor');
  caught('cmake', '  _webspace_build_lyrebird("${LYREBIRD_DIR}" "${TOR_INSTALL_DIR}")\n', '', 'lyrebird never built');
  const call = '  _webspace_build_lyrebird("${LYREBIRD_DIR}" "${TOR_INSTALL_DIR}")\n';
  caught('cmake', tor, tor.replace(call, '')
    .replace('  set(source "$ENV{WEBSPACE_TOR_SOURCE}")', `${call}  set(source "$ENV{WEBSPACE_TOR_SOURCE}")`),
  'lyrebird built where tor is not');
  caught('cmake', 'exec sh \\"$1\\" lyrebird \\"$2\\"', 'exec sh \\"$1\\" upstream \\"$2\\"', 'lyrebird as released');
  caught('cmake', '    DESTINATION "${TOR_INSTALL_DIR}"\n    USE_SOURCE_PERMISSIONS\n    COMPONENT Runtime)\n  message(STATUS "Tor: building lyrebird',
    '    DESTINATION "${TOR_INSTALL_DIR}/bin"\n    USE_SOURCE_PERMISSIONS\n    COMPONENT Runtime)\n  message(STATUS "Tor: building lyrebird',
    'lyrebird away from tor');
  caught('cmake', '    message(STATUS "Tor: WEBSPACE_LYREBIRD=none, building without lyrebird")\n    return()\n',
    '    message(STATUS "Tor: WEBSPACE_LYREBIRD=none, building without lyrebird")\n', 'none ignored');
  caught('cmake', '      "transport the machine has")\n    return()\n', '      "transport the machine has")\n',
    'no go and a build all the same');
  caught('cmake', '  set(out "${LYREBIRD_DIR}")\n',
    '  set(out "${LYREBIRD_DIR}")\n  set(ENV{IPTPROXY_WORK} "${CMAKE_BINARY_DIR}/lyrebird/work")\n', 'another work tree');
  caught('lists', '  "${CMAKE_CURRENT_SOURCE_DIR}/../build/lyrebird"\n', '  "${CMAKE_BINARY_DIR}/lyrebird"\n',
    'lyrebird kept in each tree');
  caught('verify', '[ ! -x "$transports/lyrebird" ]', '[ ! -e "$transports" ]', 'a bundle without lyrebird');
  caught('verify', '  sh "$root/go/iptproxy/build.sh" check-lyrebird "$dir"\n', '', 'lyrebird unchecked');
  caught('verify', ' ! -path "$transports/lyrebird"', ' -name nothing', 'a second transport');
  caught('verify', 'if [ "${WEBSPACE_LYREBIRD:-}" = none ]; then', 'if false; then', 'none never checked');
  caught('workflow', '          go-version-file: go/iptproxy/.go-version\n          cache: false\n\n      # The Linux Rust',
    '          cache: false\n\n      # The Linux Rust', 'a Linux build with no go');
  caught('workflow', 'apt-get install -y --no-install-recommends tor lyrebird\n', 'true\n', 'no bridge');
  caught('workflow', "          printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d\n", '', 'a tor service started');
  caught('workflow', '          WS_TOR_BESIDE: build/linux/x64/release/bundle/webspace_app\n', '',
    'the tier on the machine\'s tor');
});
