## 1. Window flag

- [x] 1.1 `ScreenCapturePlugin.kt` (`setBlocked`) registered in `MainActivity.configureFlutterEngine`.
- [x] 1.2 `ScreenCaptureGuard`: `isSupported` (Android), `appWideEnabled`, `apply` that sends only on change and resends after a failed call; pure `screenCaptureBlocked`.
- [x] 1.3 `_WebSpacePageState.build` applies the decision for the site on screen.

## 2. Settings

- [x] 2.1 `WebViewModel.blockScreenshots` in `toJson` (only when on) and `fromJson`; QR `includedKeys`; backup-compat superset.
- [x] 2.2 `kBlockScreenshotsKey` in `kExportedAppPrefs`; read at startup and after an import; saved from App settings.
- [x] 2.3 Site Privacy screen: Screen capture group, switch locked on under the app-wide switch; Privacy row summary lists it.
- [x] 2.4 App settings > Privacy: app-wide switch.
- [x] 2.5 Strings: code plus `lib/l10n/app_en.arb` in one commit, the 66 translations in the next.

## 3. Tests

- [x] 3.1 Decision truth table, send-on-change, unsupported host, resend after failure.
- [x] 3.2 Privacy screen: absent off Android, reports the site value, locked on under the app-wide switch.
- [x] 3.3 Model round trip, default unwritten, wrong-typed value reads as off; QR round trip.
