// NOTIF-015: nothing keeps a notification site running in the background.
//
// Apps that notify from the background are woken by a push channel; they do
// not stay resident. A `specialUse` keep-alive service was built for WebSpace
// once and withdrawn, and the next one would look just as reasonable in a
// diff, so these assertions make adding it a deliberate edit to this file.
// The only foreground service allowed is background audio's media playback
// (BGAUDIO-006).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

const manifests = files('android/app/src', /^AndroidManifest\.xml$/);
const kotlin = files('android/app/src', /\.(kt|java)$/);

test('the manifests are found', () => {
  assert.ok(manifests.includes('android/app/src/main/AndroidManifest.xml'));
  assert.ok(kotlin.length > 0);
});

test('no foreground-service permission but media playback', () => {
  for (const m of manifests) {
    const perms = read(m).match(/android\.permission\.FOREGROUND_SERVICE_[A-Z_]+/g) ?? [];
    for (const p of perms) {
      assert.equal(p, 'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
        `${m} declares ${p}; a foreground service may not keep notification sites running (NOTIF-015)`);
    }
  }
});

test('the only foreground service is media playback', () => {
  const services = manifests.flatMap((m) =>
    (read(m).match(/<service\b[\s\S]*?(?:\/>|<\/service>)/g) ?? [])
      .filter((s) => /foregroundServiceType=/.test(s))
      .map((s) => ({ m, s })));
  assert.equal(services.length, 1,
    `expected one foreground service, found: ${services.map((x) => x.m).join(', ')}`);
  assert.match(services[0].s, /android:name="\.MediaPlaybackService"/);
  assert.match(services[0].s, /foregroundServiceType="mediaPlayback"/);
});

test('only MediaPlaybackService enters the foreground', () => {
  const callers = kotlin
    .filter((p) => /\bstartForeground(Service)?\(/.test(read(p)));
  assert.deepEqual(callers,
    ['android/app/src/main/kotlin/org/codeberg/theoden8/webspace/MediaPlaybackService.kt'],
    'startForeground outside MediaPlaybackService would keep the process out of the freezer (NOTIF-015)');
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
