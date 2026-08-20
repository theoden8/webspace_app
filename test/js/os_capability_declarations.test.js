// Guard on what the app asks the OS for at all (LOC-REACH-004).
//
// The strongest per-site control is not a shim or a native callback: it is
// never holding the capability. A permission the app does not declare cannot
// leak through a bug, because the OS refuses before any of our code runs.
// Microphone is the worked example -- no RECORD_AUDIO, no
// NSMicrophoneUsageDescription, no audio-input entitlement -- so there is no
// path by which a page reaches a real microphone on any platform.
//
// These sets are therefore a security surface, not configuration. Widening one
// means a capability that was previously impossible becomes merely gated, so
// it has to be a deliberate edit here rather than a line quietly added to a
// manifest.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
const uniqueSorted = (xs) => [...new Set(xs)].sort();

test('Android declares exactly the permissions it needs', () => {
  const declared = uniqueSorted(
    read('android/app/src/main/AndroidManifest.xml')
      .match(/android\.permission\.[A-Z_]+/g) ?? []);
  assert.deepEqual(declared, [
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.CAMERA',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.INTERNET',
    'android.permission.POST_NOTIFICATIONS',
  ]);
  // Spelled out because it is the guarantee, not an accident of the list above:
  // no real-microphone mode exists, so the permission is never requested.
  assert.ok(!declared.includes('android.permission.RECORD_AUDIO'));
});

test('iOS declares exactly the usage descriptions it needs', () => {
  const declared = uniqueSorted(
    read('ios/Runner/Info.plist').match(/NS\w+UsageDescription/g) ?? []);
  assert.deepEqual(declared, [
    'NSCameraUsageDescription',
    'NSLocationWhenInUseUsageDescription',
    'NSPhotoLibraryUsageDescription',
  ]);
  assert.ok(!declared.includes('NSMicrophoneUsageDescription'));
});

test('macOS holds no location capability at all', () => {
  // Same WebKit as iOS, different posture: macOS has no live mode and no
  // picker button (CurrentLocationService.isSupported is Android || iOS), so
  // it declares nothing for location. Under App Sandbox, CoreLocation without
  // com.apple.security.personal-information.location is refused by the OS.
  // That makes location on macOS impossible by construction rather than gated,
  // and this test is what keeps it that way.
  const info = read('macos/Runner/Info.plist');
  assert.deepEqual(uniqueSorted(info.match(/NS\w+UsageDescription/g) ?? []),
    ['NSCameraUsageDescription']);

  for (const rel of ['macos/Runner/DebugProfile.entitlements',
                     'macos/Runner/Release.entitlements']) {
    const keys = uniqueSorted(
      (read(rel).match(/<key>([^<]*)<\/key>/g) ?? [])
        .map((k) => k.replace(/<\/?key>/g, '')));
    assert.ok(keys.includes('com.apple.security.app-sandbox'),
      `${rel} must stay sandboxed`);
    for (const forbidden of [
      'com.apple.security.personal-information.location',
      'com.apple.security.device.audio-input',
      'com.apple.security.device.microphone',
    ]) {
      assert.ok(!keys.includes(forbidden), `${rel} must not declare ${forbidden}`);
    }
  }
});

test('the platform location service is offered only where a fix is declared', () => {
  // isSupported must not name a platform whose manifest declares nothing for
  // location: that would put a "use current location" button in front of a
  // permission the app cannot hold.
  const src = read('lib/services/current_location_service.dart');
  const match = src.match(/static bool get isSupported =>[\s\S]*?;/);
  assert.ok(match, 'isSupported must stay a single readable expression');
  assert.ok(!/Platform\.isMacOS/.test(match[0]),
    'macOS declares no location usage description or entitlement');
  assert.ok(!/Platform\.isLinux|Platform\.isWindows/.test(match[0]));
});
