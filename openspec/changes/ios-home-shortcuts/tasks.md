## 1. Dart-side service layer

- [ ] 1.1 Add `ShortcutSite` value type to `lib/services/shortcut_service.dart` (`siteId`, `label`, `iconUrl`).
- [ ] 1.2 Add `ShortcutService.syncSites(List<ShortcutSite>)`. On iOS, invokes `syncSites` over the existing `org.codeberg.theoden8.webspace/shortcuts` method channel. No-op elsewhere.
- [ ] 1.3 Add `ShortcutService.isAppIntentsSupported()` returning `Future<bool>`. Invokes `isAppIntentsSupported` on iOS; false elsewhere.
- [ ] 1.4 Drop the `Platform.isAndroid` early-return in `pinShortcut`. On iOS, invoke `pinShortcut` (Swift side decides UX — opens Shortcuts.app).
- [ ] 1.5 Drop the early-return in `getLaunchSiteId` so it works on iOS too.
- [ ] 1.6 Leave `getPinnedSiteIds` Android-only (iOS returns empty set — no concept of home-screen pinning detection).

## 2. iOS App Intents (`ios/Runner/WebSpaceAppIntents.swift`)

- [ ] 2.1 Define `SiteEntity: AppEntity` (iOS 16+) with `id: String` (siteId), `name: String`, and `DisplayRepresentation` using the name.
- [ ] 2.2 Define `SiteEntityQuery: EntityQuery` (iOS 16+) reading the synced site list from `UserDefaults(suiteName: "group.org.codeberg.theoden8.webspace")` under key `shortcut_sites` (JSON-encoded `[{id, name}]`). Implement `entities(for:)`, `suggestedEntities()`, and `allEntities()` (or `entities(matching:)` if iOS 17+).
- [ ] 2.3 Define `OpenSiteIntent: AppIntent, OpenIntent` (iOS 16+). `@Parameter` is `site: SiteEntity`. `perform()` writes `pending_shortcut_site_id` to App Group UserDefaults and returns `.result()`. `openAppWhenRun = true` so iOS foregrounds WebSpace.
- [ ] 2.4 Define `WebSpaceShortcuts: AppShortcutsProvider` (iOS 16+) returning one `AppShortcut` for `OpenSiteIntent` with phrase template `"Open \(\.$site) in WebSpace"` and `systemImageName: "globe"`.

## 3. iOS method-channel bridge (`ios/Runner/ShortcutsPlugin.swift`)

- [ ] 3.1 Implement `ShortcutsPlugin(messenger:)` constructor mirroring `BackgroundTaskPlugin`. Register channel `org.codeberg.theoden8.webspace/shortcuts`.
- [ ] 3.2 Handle `isAppIntentsSupported` — return `true` if `#available(iOS 16, *)`, else `false`.
- [ ] 3.3 Handle `syncSites` — receive `{sites: [{siteId, label, iconUrl?}]}`, JSON-encode `[{id, name}]`, write to App Group UserDefaults key `shortcut_sites`. On iOS 16+ call `WebSpaceShortcuts.updateAppShortcutParameters()` to trigger re-query.
- [ ] 3.4 Handle `getLaunchSiteId` — read `pending_shortcut_site_id` from App Group UserDefaults, delete the key, return the value (or nil).
- [ ] 3.5 Handle `pinShortcut` — open `shortcuts://` via `UIApplication.shared.open`, return success. (The Dart UI shows the instructional dialog first.)
- [ ] 3.6 Handle `removeShortcut` / `getPinnedSiteIds` — return nil/empty list. Not applicable to iOS.

## 4. AppDelegate wiring

- [ ] 4.1 Add `private var shortcutsPlugin: ShortcutsPlugin?` to `AppDelegate`.
- [ ] 4.2 Instantiate `ShortcutsPlugin(messenger: controller.binaryMessenger)` alongside `LocationPlugin` and `BackgroundTaskPlugin` in `application(_:didFinishLaunchingWithOptions:)`.

## 5. Xcode project registration

- [ ] 5.1 Add `WebSpaceAppIntents.swift` and `ShortcutsPlugin.swift` PBXBuildFile + PBXFileReference entries.
- [ ] 5.2 Add both to the Runner PBXGroup children.
- [ ] 5.3 Add both to the Runner Sources build phase.

## 6. Flutter UI wiring (`lib/main.dart`)

- [ ] 6.1 Add `bool _iosAppIntentsSupported = false` to `_WebSpacePageState`.
- [ ] 6.2 In `initState` (after `_restoreAppState`), set `_iosAppIntentsSupported` via `ShortcutService.isAppIntentsSupported()`.
- [ ] 6.3 In both menu builders (around lines 3405 and 3773), replace the Android-only gate with: `(Platform.isAndroid && !_pinnedSiteIds.contains(siteId)) || (Platform.isIOS && _iosAppIntentsSupported)`. Label stays "Home Shortcut".
- [ ] 6.4 In both `addToHome` handlers, branch on platform: Android keeps current `ShortcutService.pinShortcut(...)` direct call; iOS shows an `AlertDialog` ("Open Shortcuts App" / "Cancel") explaining the flow, then calls `ShortcutService.pinShortcut(...)` on confirm to deep-link to Shortcuts.app.
- [ ] 6.5 Call `ShortcutService.syncSites(...)` after `_saveWebViewModels()` finishes (so the App Intent picker stays current as sites are added/renamed/deleted). Build the list from `_webViewModels`.
- [ ] 6.6 Also call `syncSites` once at the tail of `_restoreAppState` so a freshly installed app populates the intent index before the user opens Shortcuts.app.

## 7. Spec update

- [ ] 7.1 Edit `openspec/specs/home-shortcut/spec.md`: rewrite HS-004 to allow iOS 16+, add HS-006 (App Intents), HS-007 (App Group sync), HS-008 (instructional dialog).
- [ ] 7.2 Note in HS-005 that pinning detection is Android-only (iOS has no public API).

## 8. Tests

- [ ] 8.1 Add `test/shortcut_service_test.dart`:
  - `ShortcutSite` round-trips through the platform call arg encoder.
  - `syncSites` is a no-op on non-iOS platforms (mock the method channel — confirm no call).
  - `isAppIntentsSupported` returns false off iOS.
- [ ] 8.2 Run `fvm flutter analyze` and `fvm flutter test`.

## 9. CLAUDE.md note

- [ ] 9.1 Add a one-line entry to the per-site-settings table in CLAUDE.md mentioning iOS App Intents, OR leave alone if home-shortcut already covered (it is).
