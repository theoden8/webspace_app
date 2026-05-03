## 1. Domain-claim model and migration

- [ ] 1.1 Add `DomainClaim` + `DomainClaimKind` to `lib/web_view_model.dart` with canonical-form constructor (lowercase, strip scheme/port).
- [ ] 1.2 Extend `WebViewModel` with `List<DomainClaim> domainClaims`.
- [ ] 1.3 Add `toJson` / `fromJson` support, synthesizing `[DomainClaim.baseDomain(getBaseDomain(initUrl))]` when absent and omitting the field on write when it equals that default.
- [ ] 1.4 Unit tests in `test/domain_claim_test.dart`: canonicalization, equality, JSON round-trip, legacy synthesis, serialization stability.

## 2. Routing resolver (pure Dart)

- [ ] 2.1 Create `lib/services/link_routing_service.dart` exposing `RoutingMatch resolve(Uri url, List<WebViewModel> sites)` with specificity scoring per design D2.
- [ ] 2.2 Implement `RoutingMatch.ambiguous(List<WebViewModel>)` for top-score ties; `RoutingMatch.none()` for no match.
- [ ] 2.3 Implement `List<ClaimConflict> validateClaims(WebViewModel edited, List<WebViewModel> others)` per design D3.
- [ ] 2.4 Implement `Uri? parseWebspaceUri(Uri raw)` that returns the inner `http`/`https` target for `webspace://open?url=...` and null otherwise.
- [ ] 2.5 Unit tests `test/link_routing_test.dart`: exact > wildcard > base ordering, ties, no-match, multi-part TLDs, IPs, validator hijack/warn paths, `webspace://` parse (valid, malformed, non-http target).

## 3. Platform channel for link intents

- [ ] 3.1 Define `MethodChannel("webspace/link_intent")` with `Future<String?> getInitialUrl()` and event `onUrlArrived(url)`.
- [ ] 3.2 `LinkIntentService` in `lib/services/link_intent_service.dart` exposing `Stream<Uri>` and the initial-url future. Internally runs each URL through `parseWebspaceUri` to unwrap `webspace://open?url=...` before emitting.
- [ ] 3.3 Wire subscription in `WebSpacePage.initState`; on each URL, run the resolver and dispatch activation / picker / no-match flow.
- [ ] 3.4 Widget test `test/link_intent_dispatch_test.dart` with a fake channel: cold-start delivery, warm-start delivery, picker on ties, no-match bottom sheet.

## 4. Android integration

- [ ] 4.1 Add `ACTION_SEND` intent-filter (`mimeType="text/plain"`) on `MainActivity` in `android/app/src/main/AndroidManifest.xml`.
- [ ] 4.2 Add `<intent-filter>` for `<data android:scheme="webspace"/>` with `BROWSABLE` + `DEFAULT` categories on `MainActivity`. No `autoVerify`.
- [ ] 4.3 `MainActivity` Kotlin: capture cold-start and `onNewIntent` URL — for `ACTION_VIEW` read `intent.data`, for `ACTION_SEND` read `EXTRA_TEXT` and extract the URL substring. Deliver via the channel. Do NOT add `FLAG_ACTIVITY_NEW_TASK`.
- [ ] 4.4 Manual smoke test: share from Chrome to WebSpace; tap a `webspace://open?url=...` URL from Notes; confirm Back returns to source.

## 5. iOS integration

- [ ] 5.1 Add new target `WebSpaceShareExtension` in `ios/` with `NSExtensionActivationSupportsWebURLWithMaxCount=1`, `NSExtensionActivationSupportsText=1`.
- [ ] 5.2 Create App Group `group.com.theoden8.webspace`; entitlement on both main app and extension.
- [ ] 5.3 Register `webspace` scheme in main app `Info.plist` `CFBundleURLTypes`.
- [ ] 5.4 Implement `application:openURL:options:` (or `SceneDelegate.scene(_:openURLContexts:)`) to forward the URL to the `webspace/link_intent` channel.
- [ ] 5.5 Extension `ShareViewController` extracts URL via `NSItemProvider`, writes `pending_link` to shared `UserDefaults`, calls `extensionContext?.open(URL(string: "webspace://open?url=<encoded>")!)`, then `completeRequest`.
- [ ] 5.6 Main app reads pending URL from launch URL or App Group, then clears the App Group key.
- [ ] 5.7 Manual smoke test: share from Safari → routed to matching site; tap a `webspace://` URL in Notes → app opens.

## 6. macOS integration

- [ ] 6.1 Mirror steps 5.1–5.6 with a macOS Share Extension target under `macos/`.
- [ ] 6.2 Manual smoke test on macOS Sonoma+.

## 7. Linux `webspace://` registration

- [ ] 7.1 Author `linux/webspace.desktop` with `MimeType=x-scheme-handler/webspace;` and the runner's executable as `Exec=`.
- [ ] 7.2 Wire CMake install rule under `linux/CMakeLists.txt` to copy the desktop file to `~/.local/share/applications/` and run `update-desktop-database` post-install (best-effort).
- [ ] 7.3 Linux runner: capture cold-start argv URL and `g_application_open` (warm-start) URLs; deliver via the channel.
- [ ] 7.4 Manual smoke test: `xdg-open 'webspace://open?url=https://example.org/'` after install.

## 8. Settings + UI

- [ ] 8.1 Add "Link handling" entry in the existing settings UI.
- [ ] 8.2 Master "Handle shared links" switch persisted via `SharedPreferences` key `link_handling_enabled`. When off, the `LinkIntentService` ignores URLs and writes the flag to the App Group (iOS/macOS) so the Share Extension respects it.
- [ ] 8.3 Routing overview list: iterate all sites, show each claim → site; conflict badges from `validateClaims`.
- [ ] 8.4 Domain-claim editor in site settings: add/remove `exactHost` and `wildcardSubdomain` claims; `baseDomain` is not user-selectable. Validation runs `validateClaims`.
- [ ] 8.5 No-match bottom sheet: "Create site for <host>?" creating a new `WebViewModel` with `initUrl=<arrived URL>` and synthesized `baseDomain` claim. After accept, activate the site immediately.
- [ ] 8.6 Disambiguation picker: modal bottom sheet listing tied sites; selection activates that site.

## 9. WEBSPACE-011 wiring

- [ ] 9.1 In `LinkIntentService` dispatcher: after the resolver returns a single match, check membership in current webspace; if not a member, switch to "All" via the existing webspace selection path, then activate. Surface snackbar.
- [ ] 9.2 Widget test asserting the auto-switch + snackbar (covered by `test/link_intent_dispatch_test.dart`).

## 10. Validation and CI

- [ ] 10.1 Run `fvm flutter analyze`.
- [ ] 10.2 Run `fvm flutter test`.
- [ ] 10.3 Run `npx openspec validate default-app-for-links --strict`.
- [ ] 10.4 Update `openspec/README.md` spec table to add `link-intent-routing`.

## 11. Manual test sheet

- [ ] 11.1 Android: `ACTION_SEND` from three source apps (Chrome, Gmail, Slack).
- [ ] 11.2 Android: `webspace://open?url=...` from Notes / WhatsApp.
- [ ] 11.3 Android: Back returns to referrer (cold-start and warm-start).
- [ ] 11.4 iOS: Share Extension from Safari, Messages, Mail.
- [ ] 11.5 iOS: status-bar breadcrumb returns to source.
- [ ] 11.6 iOS: `webspace://` URL from Notes.
- [ ] 11.7 macOS: Share Extension from Safari.
- [ ] 11.8 macOS: `webspace://` via `open` CLI.
- [ ] 11.9 Linux: `xdg-open 'webspace://open?url=...'` after install.
- [ ] 11.10 Picker resolves ties.
- [ ] 11.11 No-match offers site creation.
- [ ] 11.12 WEBSPACE-011 auto-switch to "All" when matched site outside current webspace.
- [ ] 11.13 Master switch off — Android share, `webspace://`, iOS share all become no-ops.
