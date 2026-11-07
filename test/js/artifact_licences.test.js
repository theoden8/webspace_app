// LICENSE-001 and LICENSE-002 over a built APK, IPA or macOS app
// (tool/check_artifact_licences.js, run by CI on each one it builds): each
// rule caught on the mistake it is for, on apps laid out here; the real ones
// are checked where CI builds them.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const A = require('../../tool/check_artifact_licences');
const { read } = require('./helpers/source');

function dir(t, files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'artifact-licences-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [rel, bytes] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), bytes);
  }
  return root;
}

// A Mach-O or ELF stand-in: NULs up front, as a binary's header has them.
const binary = (...parts) => Buffer.concat([Buffer.alloc(64), ...parts.map((p) => Buffer.from(p, 'latin1')), Buffer.alloc(16)]);

const NOTICE = '/*\n * This program is free software: you can redistribute it and/or modify it under the terms\n'
  + ' * of the GNU General Public License as published by the Free Software Foundation.\n */\n';
const APP = 'assets/flutter_assets/AssetManifest.bin';

const scan = (root, { t, repo = {} }) => A.scan(root, { repo: dir(t, repo) }).refusals;

test('LICENSE-001 an app with no GNU notice passes, and a path that is not an app does not', (t) => {
  const root = dir(t, { [APP]: binary('assets'), 'lib/arm64-v8a/libapp.so': binary('Copyright the authors; MIT licence') });
  assert.deepEqual(scan(root, { t }), []);
  const empty = dir(t, { 'lib/arm64-v8a/libapp.so': binary('code') });
  assert.deepEqual(scan(empty, { t }), [`${empty}: no flutter_assets, so not an unpacked app`]);
});

test("LICENSE-001 a GNU notice in a text file or in a binary's strings is refused", (t) => {
  const root = dir(t, {
    [APP]: binary('assets'),
    'assets/flutter_assets/assets/js/shim.js': NOTICE,
    'Frameworks/lib.framework/lib': binary('\x07', NOTICE, '\x00more'),
    // A licence's heading kept as a JSON string, its newlines escaped.
    'Frameworks/res.framework/res': binary('\x07"', 'GNU GENERAL PUBLIC LICENSE\\n   Version 3, 29 June 2007\\n', '"\x00'),
  });
  assert.deepEqual(scan(root, { t }).sort(), [
    "Frameworks/lib.framework/lib: carries a GNU licence's notice",
    "Frameworks/res.framework/res: carries a GNU licence's notice",
    "assets/flutter_assets/assets/js/shim.js: carries a GNU licence's notice",
  ]);
});

test('LICENSE-001 a GNU notice a binary keeps in base64 is refused, wherever the run starts', (t) => {
  const encoded = Buffer.from(`${NOTICE}(function () { return 1; })();\n`.repeat(3)).toString('base64');
  for (const lead of ['', 'A', 'Ab', 'Abc']) {
    const root = dir(t, { [APP]: binary('assets'), 'lib/x86_64/libwebspace_adblock.so': binary('\x01', lead, encoded, '\x00') });
    assert.deepEqual(scan(root, { t }), ["lib/x86_64/libwebspace_adblock.so: carries a GNU licence's notice, base64-encoded"],
      `a run led by ${JSON.stringify(lead)}`);
  }
});

test("LICENSE-001 a Go binary compiling a path build.sh deletes from lyrebird is refused, go/meekutls's is not", (t) => {
  const mod = 'gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird';
  const root = dir(t, {
    [APP]: binary('assets'),
    Runner: binary(`${mod}/internal/x25519ell2.ScalarBaseMult\x00`, `${mod}@v0.0.0-20260312101154-fc105a03c0e0/transports/meeklite/transport.go\x00`),
    Fine: binary(`${mod}/transports/meeklite.(*meekutlsRoundTripper).RoundTrip\x00`, `${mod}@v0.0.0-1/transports/meeklite/meekutls.go\x00`,
      'webspace.local/hiddenkey.Representative\x00'),
  });
  assert.deepEqual(scan(root, { t }), [
    `Runner: compiles in lyrebird's internal/x25519ell2, which ${A.BUILD_SH} deletes as GPL`,
    `Runner: compiles in lyrebird's transports/meeklite/transport.go, which ${A.BUILD_SH} deletes as GPL`,
  ]);
});

test("LICENSE-001 the paths come from build.sh's GPL_PATHS, the licence text left out", () => {
  assert.deepEqual(A.goGplPaths().map((p) => p.path), read(A.BUILD_SH).match(/^GPL_PATHS='([^']*)'/m)[1]
    .split(/\s+/).filter((p) => !p.endsWith('.txt')));
  assert.deepEqual(A.goGplPaths("GPL_PATHS='a/b c.go LICENSE.txt'\n").map((p) => p.path), ['a/b', 'c.go']);
  assert.throws(() => A.goGplPaths('GPL_FILES=x\n'), /names no GPL_PATHS/);
});

test("LICENSE-001 the app's credits pass only as the checkout has them", (t) => {
  const credit = `GNU LESSER GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n${NOTICE}`;
  const repo = { 'assets/licenses/lib.txt': credit, 'assets/native_notices/pods.md': credit };
  const root = dir(t, {
    [APP]: binary('assets'),
    'assets/flutter_assets/assets/licenses/lib.txt': credit,
    'Frameworks/App.framework/flutter_assets/assets/native_notices/pods.md': credit,
    'assets/flutter_assets/assets/licenses/changed.txt': credit,
    'assets/flutter_assets/assets/other/lib.txt': credit,
  });
  assert.deepEqual(scan(root, { t, repo: { ...repo, 'assets/licenses/changed.txt': `${credit}.` } }).sort(), [
    "assets/flutter_assets/assets/licenses/changed.txt: carries a GNU licence's notice",
    "assets/flutter_assets/assets/other/lib.txt: carries a GNU licence's notice",
  ]);
});

// Each list as its upstream serves it: its header, then its entries.
const LISTS = {
  'a filter list (EasyList, AdGuard)': ['[Adblock Plus 2.0]', '! Version: 202611070216', '! Title: EasyList',
    '! Expires: 4 days (update frequency)', ...Array.from({ length: 10 }, (_, i) => `||ads${i}.example^`)].join('\n'),
  "a DNS blocklist (Hagezi's)": ["# Title: HaGeZi's Multi LIGHT", '# Homepage: https://github.com/hagezi/dns-blocklists',
    '# Number of entries: 10', ...Array.from({ length: 10 }, (_, i) => `ads${i}.example`)].join('\n'),
  'the ClearURLs rules': JSON.stringify({ providers: Object.fromEntries(Array.from({ length: 20 },
    (_, i) => [`p${i}`, { urlPattern: `^https?://p${i}\\.example`, rules: ['utm_source'] }])) }),
  "tor's GeoIP table": Array.from({ length: 100 }, (_, i) => `${16777216 + i * 256},${16777471 + i * 256},AU`).join('\n'),
  'the time zone boundaries': JSON.stringify({ type: 'FeatureCollection', features: Array.from({ length: 20 },
    (_, i) => ({ type: 'Feature', properties: { tzid: `Zone/City${i}` }, geometry: null })) }),
};

test('LICENSE-002 a copy of a list the app downloads is refused, as a file, in a binary or base64-encoded', (t) => {
  for (const [name, list] of Object.entries(LISTS)) {
    const root = dir(t, {
      [APP]: binary('assets'),
      'assets/flutter_assets/assets/data/list.txt': list,
      'lib/arm64-v8a/libapp.so': binary('\x02', list, '\x00'),
      'lib/arm64-v8a/librust.so': binary('\x03', Buffer.from(list).toString('base64'), '\x00'),
    });
    assert.deepEqual(scan(root, { t }).sort(), [
      `assets/flutter_assets/assets/data/list.txt: carries a copy of ${name}`,
      `lib/arm64-v8a/libapp.so: carries a copy of ${name}`,
      `lib/arm64-v8a/librust.so: carries a copy of ${name}, base64-encoded`,
    ], name);
  }
});

test("LICENSE-002 a hand-made sample is not a list's copy", (t) => {
  const root = dir(t, {
    [APP]: binary('assets'),
    'assets/flutter_assets/assets/easylist_sample.txt': read('test/fixtures/easylist_sample.txt'),
    'assets/flutter_assets/assets/hosts.txt': '# Title: a sample\nads.example\n',
    'assets/flutter_assets/assets/rules.json': LISTS['the ClearURLs rules'].replace(/"p1\d":\{[^}]*\},?/g, ''),
  });
  assert.deepEqual(scan(root, { t }), []);
});
