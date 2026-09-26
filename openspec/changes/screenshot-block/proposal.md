# Block screenshots

## Why

A site showing a bank balance, messages or a password manager ends up in
screenshots, screen recordings, screen-sharing sessions and the recent-apps
preview. Android can keep a window out of all of them with `FLAG_SECURE`; the
app never set it, and there was no way to ask for it, either for the whole app
or for one site.

### Platforms

- **Android**: `FLAG_SECURE` on the activity window. Screenshots are refused or
  come out blank, recordings and screen sharing show the window black, and the
  recent-apps preview is hidden.
- **iOS**: no public API keeps a screenshot out. The known workaround re-parents
  the window's layer into a secure `UITextField`, which is undocumented
  behaviour and moves Flutter's whole view hierarchy; not shipped.
- **macOS**: `NSWindow.sharingType = .none` stopped applying to ScreenCaptureKit
  in macOS 15, which is what the system screenshot and recording tools use.
- **Linux**: no mechanism on X11 or Wayland.

The switches are shown only where they work (SCREENBLOCK-001), so a user on
another platform is never told a capture is blocked when it is not.

## What Changes

- **`WebViewModel.blockScreenshots`**: per-site bool, default off, written to
  JSON only when on. Rides backups and site QR codes.
- **`blockScreenshots` app pref** in `kExportedAppPrefs`, default off, mirrored
  in `ScreenCaptureGuard.appWideEnabled`.
- **`ScreenCaptureGuard`** (`lib/services/screen_capture_guard.dart`): the pure
  `screenCaptureBlocked` decision and a bridge that sends a value only when it
  changes. `_WebSpacePageState.build` applies it, so the site shown and the
  window flag change in the same frame, and no path that moves `_currentIndex`
  can skip it.
- **`ScreenCapturePlugin.kt`**: `setBlocked` adds or clears `FLAG_SECURE` on the
  main looper.
- **UI**: a Screen capture group with a Block screenshots switch in a site's
  Privacy screen, locked on while the app-wide switch is on; a Block screenshots
  switch in App settings > Privacy. Explanations live in hints.

## Capabilities

### New Capabilities

- `screenshot-block`: SCREENBLOCK-001 to SCREENBLOCK-004.

### Modified Capabilities

- None. The archive audit (ARCH-006) needs no override: the flag writes nothing
  and names no site, it only withholds pixels, so an archive-tier site keeps the
  value the user set.

## Impact

- `lib/services/screen_capture_guard.dart` (new),
  `android/.../ScreenCapturePlugin.kt` (new), `MainActivity.kt`,
  `lib/web_view_model.dart`, `lib/main.dart`, `lib/screens/settings.dart`,
  `lib/screens/site_privacy.dart`, `lib/screens/app_settings.dart`,
  `lib/settings/app_prefs.dart`, `lib/services/site_settings_qr_codec.dart`,
  `tool/backup_compat/superset.json`.
- Strings: the group heading, the switch title, the per-site and app-wide
  hints, and the locked-on subtitle.
- Tests: `test/screen_capture_guard_test.dart`, `test/site_privacy_screen_test.dart`,
  `test/web_view_model_test.dart`, `test/site_settings_qr_codec_test.dart`.
