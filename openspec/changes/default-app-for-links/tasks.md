## 1. Domain-claim model and migration

- [x] 1.1 Add `DomainClaim` + `DomainClaimKind` to `lib/services/domain_claim.dart` (extracted from `web_view_model.dart` to avoid an import cycle) with canonical-form constructor (lowercase, strip scheme/port, drop `*.` prefix, unbracket IPv6).
- [x] 1.2 Extend `WebViewModel` with `List<DomainClaim>? domainClaims` (nullable so the synthesized default doesn't bloat on-disk JSON).
- [x] 1.3 Add `toJson` / `fromJson` support; `effectiveDomainClaims` getter synthesizes `[DomainClaim.baseDomain(getBaseDomain(initUrl))]` when absent, and `toJson` omits the field when the explicit list is null.
- [x] 1.4 Unit tests in `test/link_routing_test.dart` (canonicalization / equality / JSON round-trip) and `test/web_view_model_test.dart` (synthesized default, explicit-list round-trip).

## 2. Routing resolver (pure Dart)

- [x] 2.1 Create `lib/services/link_routing_service.dart` exposing `RoutingMatch resolve(Uri url, List<RoutableSite> sites)` with specificity scoring per design D2b.
- [x] 2.2 Implement `RoutingSingle` / `RoutingAmbiguous` / `RoutingNone` (sealed) for top-score ties and no-match cases.
- [x] 2.3 Implement `List<ClaimConflict> validateClaims(String editedSiteId, List<DomainClaim> editedClaims, List<RoutableSite> others)` per design D3.
- [x] 2.4 Implement `Uri? parseWebspaceUri(Uri raw)` that returns the inner `http`/`https` target for `webspace://open?url=...` and null otherwise.
- [x] 2.5 Implement `String? strippedHomeUrl(Uri url)` returning `<scheme>://<host>[:port]/` for valid http(s) Uris (LIR-009 path stripping).
- [x] 2.6 Implement `List<DomainClaim> claimsToAdoptHost(String host)` returning `[exactHost, wildcardSubdomain(base)]` for the LIR-010 "send domain to a site" option, deduplicated by callers against existing claim lists.
- [x] 2.7 Unit tests `test/link_routing_test.dart`: exact > wildcard > base ordering, ties, no-match, multi-part TLDs, IPs, validator hijack/warn paths, `webspace://` parse (valid, malformed, non-http target), stripped-path edge cases (port preservation, query/fragment dropped, malformed rejection), `claimsToAdoptHost` shape + dedup.

## 3. Platform channel for link intents

- [x] 3.1 Reuse the existing `MethodChannel("org.codeberg.theoden8.webspace/share_intent")` (added in #292) with `consumeLaunchUrl` and a new `consumeLaunchHtml` method for HTML payloads (LIR-012).
- [x] 3.2 `ShareIntentService` in `lib/services/share_intent_service.dart` exposes `consumeLaunchUrl()` (returns `String?`) and `consumeLaunchHtml()` (returns `InboundHtmlShare?`). Webspace-scheme unwrap happens in `LinkRoutingService.parseWebspaceUri`, called by the dispatch engine when a `webspace://` URL arrives.
- [x] 3.3 `_handleShareIntent` in `lib/main.dart` consumes both channels (HTML first), wraps the payload in `InboundUrl` / `InboundHtml`, and hands it to `LinkIntentDispatchEngine.dispatch`. Wired on cold start (`runApp`) and warm-start lifecycle resume.
- [ ] 3.4 Widget test `test/link_intent_dispatch_test.dart` with a fake channel: cold-start delivery, warm-start delivery, picker on ties, no-match bottom sheet.

## 4. Android integration

- [x] 4.1 `ACTION_SEND` intent-filter on `MainActivity` in `android/app/src/main/AndroidManifest.xml`. Mime types: `text/plain`, `text/html`, `application/xhtml+xml` (LIR-012).
- [x] 4.2 `<intent-filter>` for `<data android:scheme="webspace"/>` with `BROWSABLE` + `DEFAULT` categories on `MainActivity`. No `autoVerify`.
- [x] 4.3 `MainActivity` Kotlin: `captureSharePayload` reads cold-start and `onNewIntent` intents — `ACTION_VIEW` with a `webspace://` URI passes the raw string through; `ACTION_SEND` with `EXTRA_TEXT` → URL substring extraction; `ACTION_SEND` with `EXTRA_STREAM` (HTML mime or `.html`/`.htm` extension) → reads file content into memory + extracts `<title>` (or filename) for the suggested title. No `FLAG_ACTIVITY_NEW_TASK`.
- [ ] 4.4 Manual smoke test: share from Chrome to WebSpace; share an HTML file from Files / Drive; tap a `webspace://open?url=...` URL from Notes; confirm Back returns to source.

## 5. iOS integration

> Basic URL share already lands via PR #297 (`Register WebSpace as iOS share target`); the channel name and `consumeLaunchUrl` API are reused. The Share Extension target, App Group, and `webspace://` scheme registration are still pending.

- [x] 5.1 Share Extension target ships with `NSExtensionActivationSupportsWebURLWithMaxCount=1`, `NSExtensionActivationSupportsText=1`, and `NSExtensionActivationSupportsFileWithMaxCount=1` (HTML files for LIR-012) in `ios/ShareExtension/Info.plist`.
- [x] 5.2 App Group `group.org.codeberg.theoden8.webspace` entitled on both main app and extension (`ios/ShareExtension/ShareExtension.entitlements`).
- [x] 5.3 `webspace` scheme registered in `ios/Runner/Info.plist` `CFBundleURLTypes` (already in master before this change).
- [x] 5.4 `application:openURL:options:` accepts `webspace://open?url=<encoded http(s)>`, `webspace://share?url=...` (legacy), `webspace://qr/...`, and `webspace://openhtml` (HTML handoff trigger); pending URL is exposed to Dart via the existing `share_intent` channel. `consumeLaunchHtml` drains the app-group HTML container (see 5.6).
- [x] 5.5 Extension `ShareViewController` extracts an HTTP(S) URL or an HTML document (`public.html` attachment, `Data`, or a file URL ending `.html`/`.htm`/`.xhtml`). URL → `pending_share_url` in app-group `UserDefaults` + `webspace://share?url=`. HTML → document written to `pending_share.html` in the shared app-group container, title/source in `UserDefaults`, then `webspace://openhtml`. HTML wins over URL.
- [x] 5.6 Main app `consumeLaunchHtml` (`AppDelegate.swift`) reads `pending_share.html` from the App Group container plus title/source keys, returns them to Dart, then deletes the file + keys so the same file is not imported twice. URL drain via `drainAppGroupPendingUrl` unchanged.
- [ ] 5.7 Manual smoke test (**requires device/Xcode**): share URL from Safari, share HTML file from Files, tap `webspace://` URL in Notes.

## 6. macOS integration

- [x] 6.1a `webspace` scheme registered in `macos/Runner/Info.plist` `CFBundleURLTypes`. `application:openURLs:` forwards `webspace://open` / `webspace://qr` to the existing `share_intent` channel; `consumeLaunchHtml` returns null until the Share Extension target ships.
- [ ] 6.1b Add a macOS Share Extension target with the same activation rules as iOS 5.1 + App Group entitlement. **Requires Xcode** — cannot land from headless tooling.
- [ ] 6.2 Manual smoke test on macOS Sonoma+.

## 7. Linux `webspace://` registration

- [x] 7.1 `linux/webspace.desktop` with `MimeType=x-scheme-handler/webspace;` and `Exec=webspace_app %u`. `StartupWMClass` matches the GTK app.
- [x] 7.2 CMake install rule in `linux/CMakeLists.txt` bundles the desktop file alongside the runner. Distribution packagers must additionally copy it to `${XDG_DATA_DIRS}/applications/` and run `update-desktop-database`; documented inline.
- [x] 7.3 Linux runner now sets `G_APPLICATION_HANDLES_OPEN`, intercepts `webspace://...` arguments in `local_command_line` and routes them through `GApplication::open`; the `share_intent` `FlMethodChannel` is registered on the FlView and exposes `consumeLaunchUrl` + a stub `consumeLaunchHtml`.
- [ ] 7.4 Manual smoke test: `xdg-open 'webspace://open?url=https://example.org/'` after install.

## 8. Settings + UI

- [x] 8.1 "Link handling" entry in the existing app settings (`AppSettingsScreen` opens `LinkHandlingSettingsScreen`).
- [x] 8.2 Master "Handle shared links" switch persisted via `SharedPreferences` key `linkHandlingEnabled` and registered in `kExportedAppPrefs` so it round-trips through backups. `_handleShareIntent` early-returns (logs and drops) when off, for both URL and HTML payloads. Writing the flag to the iOS/macOS App Group still depends on the Share Extension target work in 5.x.
- [x] 8.3 Routing overview list in `LinkHandlingSettingsScreen`: iterates `_webViewModels`, renders each site's effective claims as chips, surfaces a "N conflicts" badge from `LinkRoutingService.validateClaims`. Tapping a row pops the screen and reopens the per-site settings.
- [x] 8.4 `DomainClaimsEditor` widget embedded in `lib/screens/settings.dart`. Lets the user add/remove `exactHost` and `wildcardSubdomain` claims; the synthesized `baseDomain` claim shows but cannot be removed when it's the last claim. Hijack and overlap conflicts surface inline against the claim row. `onChanged` returns `null` when the user reverts to the synthesized default so on-disk JSON stays minimal.
- [x] 8.5 LIR-010 dispatch picker: single bottom sheet with up to three option groups — (1) one row per resolver winner ("Match router default" fast-pathed when there is exactly one), (2) "Send <host> (and subdomains) to a site" → site picker → append `claimsToAdoptHost(host)` (deduped) and activate, (3) "Create new site for <host>" → `WebViewModel(initUrl: strippedHomeUrl(url), domainClaims: [baseDomain(...)])`, then navigate the new webview to the full inbound URL on first activation.
- [x] 8.6 "Test routing" entry in `LinkHandlingSettingsScreen` re-runs the `LinkIntentDispatchEngine` for an arbitrary URL the user types, which surfaces the LIR-010 picker on demand even when a single resolver match exists. Disabled when the master switch is off.

## 9. WEBSPACE-011 wiring

- [x] 9.1 `_maybeSwitchToAllForSite` runs at the top of every executor (`_executeOpenInMain`, `_executeOpenNested`, `_executeBindAndOpen`, `_executeCreateSite`, `_executeCreateSiteFromHtml` via `_registerNewSite`) — when the matched site is outside the current named webspace, the active webspace switches to "All" with a snackbar before activation.
- [ ] 9.2 Widget test asserting the auto-switch + snackbar. Engine-level coverage is provided by `test/link_intent_dispatch_engine_test.dart`; a full widget test of `_WebSpacePageState` is heavy because the dispatcher is currently embedded there. Track as follow-up alongside 3.4 once the dispatcher widget is extracted.

## 10. Validation and CI

- [x] 10.1 `fvm flutter analyze` — clean for new files; only pre-existing repo lints remain.
- [x] 10.2 `fvm flutter test` — full suite green. Engine + widget tests added: `test/link_intent_dispatch_engine_test.dart`, `test/link_routing_test.dart`, `test/link_handling_settings_test.dart`, plus extensions to `test/web_view_model_test.dart`.
- [x] 10.3 `npx openspec validate default-app-for-links --strict` — passes.
- [x] 10.4 `openspec/README.md` lists `link-intent-routing` in the structure table.

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
