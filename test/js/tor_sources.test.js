// Every tor the Linux packages ship comes from a pinned source that stays
// where the pin names it. dist.torproject.org keeps only current releases, so
// a pin there stopped resolving once Tor Browser moved on (15.0.26, after
// 16.0); the Tor Project's archive keeps every one.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const ARCHIVE = 'https://archive.torproject.org/tor-package-archive/';

test("the Linux build downloads the Tor Expert Bundle from the Tor Project's archive (TOR-027)", () => {
  const rel = 'linux/tor_bundle.cmake';
  const urls = [...read(rel).matchAll(/"(https:\/\/[^"]+)"/g)].map((m) => m[1]);
  assert.ok(urls.length > 0, `${rel} names no download`);
  for (const url of urls) {
    assert.ok(url.startsWith(`${ARCHIVE}torbrowser/`),
      `${rel} downloads ${url}, not from ${ARCHIVE}, which keeps every release`);
  }
});
