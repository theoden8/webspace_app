// Structural gate for PLATFORM-007: the native launch screen follows the
// system appearance. The Flutter template ships the iOS storyboard with a
// hard-coded white background, and a `flutter create .` over the platform
// dirs brings it back; nothing renders the launch screen in a test, so this
// is the only thing that would notice.
//
// Spec: openspec/specs/platform-support/spec.md (PLATFORM-007).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const repo = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(repo, p), 'utf8');

const STORYBOARD = 'ios/Runner/Base.lproj/LaunchScreen.storyboard';
const MANIFEST = 'android/app/src/main/AndroidManifest.xml';
const STYLES = 'android/app/src/main/res/values/styles.xml';
const STYLES_NIGHT = 'android/app/src/main/res/values-night/styles.xml';
const LAUNCH_BG = 'android/app/src/main/res/drawable-v21/launch_background.xml';

function launchThemeParent(styles) {
  const m = styles.match(/<style\s+name="LaunchTheme"\s+parent="([^"]+)"/);
  return m ? m[1] : null;
}

test('PLATFORM-007: iOS launch screen background is a system colour', () => {
  const sb = read(STORYBOARD);
  const bg = sb.match(/<color key="backgroundColor"[^>]*\/>/g) || [];
  assert.ok(bg.length > 0, `${STORYBOARD} has no view backgroundColor`);
  for (const c of bg) {
    assert.match(
      c, /systemColor="systemBackgroundColor"/,
      `${STORYBOARD} sets ${c}. A fixed colour does not follow dark mode; ` +
      'use systemColor="systemBackgroundColor".',
    );
  }
  assert.match(
    sb, /<systemColor name="systemBackgroundColor">/,
    `${STORYBOARD} references systemBackgroundColor without declaring it ` +
    'under <resources>, which ibtool rejects.',
  );
});

test('PLATFORM-007: Android LaunchTheme has a dark night variant', () => {
  assert.match(read(MANIFEST), /android:theme="@style\/LaunchTheme"/);
  const day = launchThemeParent(read(STYLES));
  const night = launchThemeParent(read(STYLES_NIGHT));
  assert.ok(day, `${STYLES} must define LaunchTheme`);
  assert.ok(night, `${STYLES_NIGHT} must define LaunchTheme`);
  assert.doesNotMatch(
    night, /Light/,
    `${STYLES_NIGHT} LaunchTheme inherits ${night}, a light theme, so its ` +
    '?android:colorBackground is light in dark mode.',
  );
});

test('PLATFORM-007: Android launch background draws the theme colour', () => {
  const bg = read(LAUNCH_BG);
  assert.match(bg, /android:drawable="\?android:colorBackground"/);
  assert.doesNotMatch(
    bg, /@android:color\/|android:drawable="#/,
    `${LAUNCH_BG} names a fixed colour, which does not follow dark mode.`,
  );
});
