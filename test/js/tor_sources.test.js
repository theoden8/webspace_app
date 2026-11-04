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
  assert.doesNotMatch(code, /pluggable_transports/, `${rel} ships a pluggable transport`);
});
