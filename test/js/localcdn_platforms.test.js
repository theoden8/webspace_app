// LocalCDN outside Android (LCDN-013): no native code on iOS, macOS or Linux
// serves a cached CDN copy, so the app offers LocalCDN on Android alone and
// every other platform's CDN requests go out unchanged.
//
// Rung 5: that no native file intercepts a request is an absence, which no
// type states; the Android half, the copy served with CORS, is
// LocalCdnPerSiteTest's.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { read } = require('./helpers/source');

const ROOT = path.resolve(__dirname, '../..');
const NATIVE = /\.(swift|m|mm|h|cc|c|cpp)$/;

/** Every native source file under [dir], skipping generated trees. */
function nativeFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (['Pods', 'build', 'flutter', 'ephemeral', '.symlinks'].includes(entry.name)) continue;
      out.push(...nativeFiles(rel));
    } else if (NATIVE.test(entry.name)) {
      out.push(rel);
    }
  }
  return out;
}

/** The native files in [files] that name LocalCDN. */
function servers(files, { text }) {
  return files.filter((f) => /local_?cdn|cdnTables/i.test(text(f)));
}

test('only Android serves a cached CDN copy, and only Android offers '
    + 'LocalCDN (LCDN-013)', () => {
  const files = ['ios', 'macos', 'linux'].flatMap(nativeFiles);
  assert.ok(files.length > 20, `only ${files.length} native files found: the walk reads nothing`);
  assert.deepEqual(servers(files, { text: read }), []);
  assert.match(read('lib/services/localcdn_service.dart'),
    /static bool get offered => debugOffered \?\? hostIsAndroid;/,
    'LocalCDN is offered where no native code serves it');

  const planted = files[0];
  assert.deepEqual(
    servers(files, { text: (f) => (f === planted ? 'let localCdnEnabled = true' : read(f)) }),
    [planted]);
});
