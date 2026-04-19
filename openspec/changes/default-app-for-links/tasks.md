## 1. Domain-claim model and migration

- [ ] 1.1 Add `DomainClaim` + `DomainClaimKind` to `lib/web_view_model.dart` with canonical-form constructor (lowercase, strip scheme/port).
- [ ] 1.2 Extend `WebViewModel` with `List<DomainClaim> domainClaims`.
- [ ] 1.3 Add `toJson` / `fromJson` support for `domainClaims`, synthesizing `[DomainClaim.baseDomain(getBaseDomain(initUrl))]` when absent and omitting the field on write when it equals that default.
- [ ] 1.4 Add unit tests in `test/domain_claim_test.dart`: canonicalization, equality, JSON round-trip, legacy synthesis, serialization stability.

## 2. Link routing resolver (pure Dart)

- [ ] 2.1 Create `lib/services/link_routing_service.dart` exposing `RoutingMatch resolve(Uri url, List<WebViewModel> sites)` with specificity scoring per design D2.
- [ ] 2.2 Implement tie detection that returns `RoutingMatch.ambiguous(List<WebViewModel>)` when top-score candidates > 1.
- [ ] 2.3 Implement `List<ClaimConflict> validateClaims(WebViewModel edited, List<WebViewModel> others)` per design D3 (block on init-URL base-domain hijack, warn on other overlaps).
- [ ] 2.4 Unit tests in `test/link_routing_test.dart`: exact > wildcard > base, ties, no-match, multi-part TLDs, IPs (should not route via claims), validator hijack/warn paths.

## 3. Platform channel for link intents

- [ ] 3.1 Define `MethodChannel("webspace/link_intent")` with methods `getInitialUrl()` and event `onUrlArrived(url)`.
- [ ] 3.2 `LinkIntentService` in `lib/services/link_intent_service.dart` exposing `Stream<Uri>` and an initial-url future.
- [ ] 3.3 Wire subscription in `WebSpacePage.initState`; on each URL, run the resolver and dispatch activation / picker / no-match flow.
- [ ] 3.4 Widget test `test/link_intent_dispatch_test.dart` using a fake channel to verify resolver is invoked and the picker surfaces on ties.

## 4. Android integration

- [ ] 4.1 Add `ACTION_SEND` intent-filter (`mimeType="text/plain"`) to `MainActivity` in `android/app/src/main/AndroidManifest.xml`.
- [ ] 4.2 Add one `<activity-alias>` per curated host (`twitter.com`, `x.com`, `linkedin.com`, `mastodon.social`, `reddit.com`, `news.ycombinator.com`, `github.com`, `gitlab.com`, `youtube.com`, `duckduckgo.com`) with `android:enabled="false"`, `autoVerify="false"`, `BROWSABLE` category.
- [ ] 4.3 Confirm flavor manifests (`fmain`, `fdroid`, `fdebug`) inherit aliases without flavor-specific differences.
- [ ] 4.4 Implement `MainActivity` Kotlin: capture cold-start and `onNewIntent` URL (both `ACTION_VIEW` data and `ACTION_SEND` `EXTRA_TEXT`), deliver via `webspace/link_intent` channel. Do NOT add `FLAG_ACTIVITY_NEW_TASK` to `onNewIntent` handling.
- [ ] 4.5 Expose `setHostHandlerEnabled(host, enabled)` on the channel; implementation calls `PackageManager.setComponentEnabledSetting` with `DONT_KILL_APP`.
- [ ] 4.6 Manual test matrix: share from Chrome/Gmail/Slack to WebSpace; tap a twitter.com link with handler on vs off; confirm "Back" returns to referrer.

## 5. iOS integration

- [ ] 5.1 Add new target `WebSpaceShareExtension` in `ios/` with `NSExtensionActivationSupportsWebURLWithMaxCount=1` and `NSExtensionActivationSupportsText=1`.
- [ ] 5.2 Create App Group `group.com.theoden8.webspace`; entitlement on both main app and extension.
- [ ] 5.3 Register URL scheme `webspace` in main app `Info.plist`; implement `SceneDelegate` handler (or `application:openURL:options:`) to pass the URL to the `webspace/link_intent` channel.
- [ ] 5.4 Extension `ShareViewController` extracts URL from `NSItemProvider`, writes `pending_link` to shared `UserDefaults`, calls `extensionContext?.open(URL(string: "webspace://open?url=<encoded>")!)`, then `completeRequest`.
- [ ] 5.5 Main app reads pending URL from launch URL or App Group, then clears the key.
- [ ] 5.6 Manual test: share a link from Safari; confirm main app opens and routes; confirm "← Safari" breadcrumb returns user.

## 6. macOS integration

- [ ] 6.1 Mirror steps 5.1–5.5 with a macOS Share Extension target under `macos/`.
- [ ] 6.2 Manual test: share a link from Safari on macOS.

## 7. Settings + UI

- [ ] 7.1 Add "Link handling" screen as a new entry in the existing settings UI.
- [ ] 7.2 Master "Handle shared links" switch persisted via `SharedPreferences` key `link_handling_enabled`; when off, disable all aliases (Android) and set shared flag (iOS/macOS).
- [ ] 7.3 Per-host toggle list (Android only); toggle state reflects `PackageManager.getComponentEnabledSetting`.
- [ ] 7.4 Routing overview list: iterate all sites, show each claim → site; show conflict badges from `validateClaims`.
- [ ] 7.5 Domain-claim editor in site settings: add/remove exact and wildcard claims (baseDomain not user-selectable); validation uses `validateClaims`.
- [ ] 7.6 No-match bottom sheet: "Create site for <host>?" flow that creates a new `WebViewModel` with the full URL as `initUrl`.
- [ ] 7.7 Disambiguation picker: modal bottom sheet listing tied sites.

## 8. Cookie-isolation integration ("All" webspace scope)

- [ ] 8.1 Update `lib/main.dart` conflict detection to compute the expanded conflict key (ISO-001 MODIFIED) only when `selectedWebspaceId == __all_webspace__`.
- [ ] 8.2 Show snackbar when an unload happens due to claim overlap (per ISO-001 scenario).
- [ ] 8.3 Integration test `test/all_webspace_claim_conflict_test.dart`: two sites with overlapping claims conflict in "All" but coexist in a named webspace.

## 9. Validation and CI

- [ ] 9.1 Run `fvm flutter analyze`.
- [ ] 9.2 Run `fvm flutter test`.
- [ ] 9.3 Run `npx openspec validate default-app-for-links`.
- [ ] 9.4 Update `openspec/README.md` spec table to reference `link-intent-routing`.

## 10. Manual test sheet (tracked in this change, not archived)

- [ ] 10.1 Android: `ACTION_SEND` from three source apps.
- [ ] 10.2 Android: `ACTION_VIEW` for each curated host with handler on/off.
- [ ] 10.3 Android: Back returns to referrer (cold-start and warm-start).
- [ ] 10.4 iOS: Share Extension from Safari, Messages, Mail.
- [ ] 10.5 iOS: status-bar breadcrumb returns to source.
- [ ] 10.6 macOS: Share Extension from Safari.
- [ ] 10.7 Claim-overlap conflict in "All" webspace unloads correctly.
- [ ] 10.8 Named webspace ignores claim-overlap (legacy behavior).
- [ ] 10.9 No-match offers site creation.
- [ ] 10.10 Picker resolves ties.
