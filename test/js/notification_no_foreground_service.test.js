// NOTIF-015: nothing keeps a notification site running in the background.
//
// Apps that notify from the background are woken by a push channel; they do
// not stay resident. A `specialUse` keep-alive service was built for WebSpace
// once and withdrawn, and the next one would look just as reasonable in a
// diff, so these assertions make adding it a deliberate edit to this file.
// The foreground services allowed are background audio's media playback
// (BGAUDIO-006) and the screen share's media projection (SHARE-018), which
// Android requires for a projection and which runs only while a share the
// user started through Android's own prompt does.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

const manifests = files('android/app/src', /^AndroidManifest\.xml$/);
const kotlin = files('android/app/src', /\.(kt|java)$/);

test('the manifests are found', () => {
  assert.ok(manifests.includes('android/app/src/main/AndroidManifest.xml'));
  assert.ok(kotlin.length > 0);
});

const ALLOWED_TYPES = {
  'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK': 'BGAUDIO-006',
  'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION': 'SHARE-018',
};

test('no foreground-service permission but media playback and projection', () => {
  for (const m of manifests) {
    const perms = read(m).match(/android\.permission\.FOREGROUND_SERVICE_[A-Z_]+/g) ?? [];
    for (const p of perms) {
      assert.ok(p in ALLOWED_TYPES,
        `${m} declares ${p}; a foreground service may not keep notification sites running (NOTIF-015)`);
    }
  }
});

test('the foreground services are media playback and the screen share', () => {
  const services = manifests.flatMap((m) =>
    (read(m).match(/<service\b[\s\S]*?(?:\/>|<\/service>)/g) ?? [])
      .filter((s) => /foregroundServiceType=/.test(s))
      .map((s) => ({ m, s })));
  const named = services.map(({ s }) => [
    s.match(/android:name="([^"]+)"/)?.[1],
    s.match(/foregroundServiceType="([^"]+)"/)?.[1],
  ]).sort();
  assert.deepEqual(named, [
    ['.MediaPlaybackService', 'mediaPlayback'],
    ['.ScreenShareService', 'mediaProjection'],
  ]);
});

test('only the two services enter the foreground', () => {
  const callers = kotlin
    .filter((p) => /\bstartForeground(Service)?\(/.test(read(p)));
  const root = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace';
  assert.deepEqual(callers, [
    `${root}/MediaPlaybackService.kt`,
    `${root}/ScreenSharePlugin.kt`,
    `${root}/ScreenShareService.kt`,
  ], 'startForeground elsewhere would keep the process out of the freezer (NOTIF-015)');
});

test('the screen share service starts only from Android\'s capture prompt', () => {
  // ScreenSharePlugin starts it from onActivityResult alone, after the user's
  // yes: a share is never a way to keep a page resident.
  const src = read('android/app/src/main/kotlin/org/codeberg/theoden8/webspace/ScreenSharePlugin.kt');
  const starts = [...src.matchAll(/startForegroundService\(/g)];
  assert.equal(starts.length, 1);
  const enclosing = [...src.slice(0, starts[0].index).matchAll(/\bfun (\w+)\(/g)].pop();
  assert.equal(enclosing?.[1], 'onActivityResult',
    'startForegroundService must be called from onActivityResult');
  assert.match(src, /resultCode != Activity\.RESULT_OK \|\| data == null/);
});

test('iOS holds no background mode that would keep a page alive', () => {
  const plist = read('ios/Runner/Info.plist');
  const block = /<key>UIBackgroundModes<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(plist);
  assert.ok(block);
  const modes = [...block[1].matchAll(/<string>([^<]+)<\/string>/g)].map((m) => m[1]).sort();
  assert.deepEqual(modes, ['audio', 'fetch', 'processing'],
    '`audio` is background audio (BGAUDIO-003), `fetch` and `processing` the ' +
    'notification wake; `location` or `voip` held for a notification site is the ' +
    'iOS keep-alive NOTIF-015 rules out');
});
