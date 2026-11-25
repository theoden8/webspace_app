// LocalCDN outside Android (LCDN-013): no native code on iOS, macOS or Linux
// serves a cached CDN copy, so the app offers LocalCDN on Android alone and
// every other platform's CDN requests go out unchanged.
//
// Rung 5: that no native file intercepts a request is an absence, which no
// type states; the Android half, the copy served with CORS, is
// LocalCdnPerSiteTest's.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

const NATIVE = /\.(swift|m|mm|h|cc|c|cpp)$/;
// Trees a build or a pod install writes, which hold no source of ours.
const GENERATED = /\/(Pods|build|ephemeral|\.symlinks)\//;

/** Every native source file under [dir], skipping generated trees. */
function nativeFiles(dir) {
  return files(dir, NATIVE).filter((f) => !GENERATED.test(f));
}

/** The native files in [sources] that name LocalCDN. */
function servers(sources, { text }) {
  return sources.filter((f) => /local_?cdn|cdnTables/i.test(text(f)));
}

test('only Android serves a cached CDN copy, and only Android offers '
    + 'LocalCDN (LCDN-013)', () => {
  const native = ['ios', 'macos', 'linux'].flatMap(nativeFiles);
  assert.ok(native.length > 20, `only ${native.length} native files found: the walk reads nothing`);
  assert.deepEqual(servers(native, { text: read }), []);
  assert.match(read('lib/services/localcdn_service.dart'),
    /static bool get offered => debugOffered \?\? hostIsAndroid;/,
    'LocalCDN is offered where no native code serves it');

  const planted = native[0];
  assert.deepEqual(
    servers(native, { text: (f) => (f === planted ? 'let localCdnEnabled = true' : read(f)) }),
    [planted]);
});
