## 1. Native iOS plugin (Tor.framework integration)

- [ ] 1.1 Add `pod 'Tor', '~> 408.10'` (pinned tag) to `ios/Podfile` under the `Runner` target; keep gated by the existing iOS-only platform clause.
- [ ] 1.2 Create `ios/Runner/TorControllerPlugin.swift` registering `FlutterMethodChannel <bundleId>/tor` and `FlutterEventChannel <bundleId>/tor/events`. Register in `AppDelegate.swift` alongside `BackgroundTaskPlugin`.
- [ ] 1.3 Implement `start()` — builds a `TorConfiguration` with `SocksPort auto IsolateSOCKSAuth IsolateDestAddr`, control-port cookie auth, ephemeral `DataDirectory` under `NSCachesDirectory/Tor/`, spawns `TorThread`, subscribes to control-port `BOOTSTRAP` events.
- [ ] 1.4 Implement `status()` — returns `{state, bootstrapPct, socksHost, socksPort}` synchronously; emits the same shape via the event channel as state changes.
- [ ] 1.5 Implement `rebuildCircuits()` — sends `SIGNAL NEWNYM` via the control port. Rate-limit at the plugin layer (no-op if last NEWNYM was less than 10s ago).
- [ ] 1.6 Implement `stop()` — graceful shutdown via `TorThread.cancel()`, awaits termination with a 5s timeout then force-exits the thread. Clears in-memory port info.
- [ ] 1.7 Add `NSPrivacyAccessedAPITypes` entries to `Info.plist` for the file-timestamp / disk-space / boot-time required-reason APIs Tor.framework uses (codes `C617.1`, `85F4.1`, `35F9.1`).

## 2. Dart Tor service

- [ ] 2.1 Add `lib/services/tor_service.dart`: `TorService.instance`, `TorStatus` sealed class hierarchy (`Stopped`, `Starting`, `Bootstrapping(pct)`, `Up`, `Errored(msg)`), `Stream<TorStatus> statusStream` (broadcast), `bool isAvailable` (returns `Platform.isIOS` initially).
- [ ] 2.2 Implement refcount + 60s debounce timer: `maybeStart(reason)`, `release(reason)`, internal `_count` keyed by reason string for diagnostics; idle-stop timer scheduled when `_count == 0`, canceled on reactivation.
- [ ] 2.3 Implement `socksFor({String? siteId, bool appGlobal = false})` returning a `UserProxySettings` with type SOCKS5, address from current `socksEndpoint`, username = `siteId ?? '__webspace_app_global__'`, password = `_sessionSecret` (random 32-byte hex generated once per instance).
- [ ] 2.4 Implement `rebuildCircuits()` — invokes the plugin method, surfaces any rate-limit response back to the caller (no-op snackbar in UI).
- [ ] 2.5 Wire the plugin's event channel to `statusStream`; map Swift state codes to Dart `TorStatus` cases.
- [ ] 2.6 Bootstrap timeout: if `Bootstrapping(*)` for >90s without reaching `Up`, transition to `Errored("bootstrap timed out")` and stop the underlying thread.
- [ ] 2.7 Stub `TorService` on non-iOS platforms — every method is a no-op, `isAvailable == false`, `statusStream` emits only `Stopped`. No native plugin reference at all on Android/macOS/Linux builds.

## 3. Per-site `useTor` field

- [ ] 3.1 Add `bool useTor` to `WebViewModel` ([lib/web_view_model.dart](../../../lib/web_view_model.dart)), default `false`. JSON: `toJson` emits when true, `fromJson` decodes with `false` default.
- [ ] 3.2 Thread `useTor` through `WebViewConfig`, `launchUrl` signature in [lib/main.dart](../../../lib/main.dart), `InAppWebViewScreen` constructor in [lib/screens/inappbrowser.dart](../../../lib/screens/inappbrowser.dart), and the `launchUrlFunc` typedef + both call sites in `web_view_model.dart` — the full nested-webview propagation per the CLAUDE.md rule.
- [ ] 3.3 In `WebViewModel.updateProxySettings`: when `useTor` flips from `false → true`, call `TorService.instance.maybeStart(siteId)`; when `true → false`, call `TorService.instance.release(siteId)`. Dispose the webview on iOS so the rebuild picks up the new proxy.
- [ ] 3.4 On `WebViewModel` deletion / app shutdown, ensure orphaned `useTor=true` sites release their refcount (mirror the proxy-password GC sites in `main.dart` — startup, post-import, post-delete).

## 4. Proxy resolution and outbound HTTP

- [ ] 4.1 Add `ProxyType.TOR` to the enum in [lib/settings/proxy.dart](../../../lib/settings/proxy.dart). Serialize as a new integer value (append; do NOT renumber existing values — would break backups).
- [ ] 4.2 In [lib/services/outbound_http.dart](../../../lib/services/outbound_http.dart): extend `clientFor` so `ProxyType.TOR` (and `useTor=true`) resolves via `TorService.instance.socksFor(...)`; the returned `UserProxySettings` is then handled by the existing SOCKS5 branch (no duplicate `socks5_proxy` plumbing).
- [ ] 4.3 In `resolveEffectiveProxy`: per-site `useTor=true` wins over both manual per-site proxy and global TOR. Per-site DEFAULT with `globalOutboundProxy.type == TOR` resolves with the `__webspace_app_global__` isolation tag, NOT the site's `siteId`.
- [ ] 4.4 Fail-closed: when `useTor` or `TOR` is in play and `TorService.status != Up`, return `OutboundClientBlocked` from `clientFor`. Tests using `RecordingFactory` assert no fallback `http.Client()` is constructed.
- [ ] 4.5 In [lib/services/webview.dart](../../../lib/services/webview.dart) `_userProxyToInappProxy`: when `useTor=true` or type `TOR`, fetch from `TorService.instance.socksFor(siteId: ...)` and emit the SOCKS5 map the fork's iOS native side consumes.

## 5. Bootstrap interstitial

- [ ] 5.1 Add a Flutter screen `lib/screens/tor_bootstrap.dart` that subscribes to `TorService.statusStream`, renders a determinate progress bar (`Bootstrapping(pct)`), an error + Retry button (`Errored`), and on `Up` calls `Navigator.pushReplacement` with the `next` URL.
- [ ] 5.2 In `WebViewModel`'s navigation policy hook (existing `shouldOverrideUrlLoading`): when the destination has `useTor=true` and `TorService.status != Up`, rewrite to `webspace://tor-bootstrap?next=<encoded>`. Hook the existing custom-scheme dispatcher (same surface used by `default-app-for-links`).
- [ ] 5.3 Unit test: feeding the navigation hook a `useTor` site with `Bootstrapping(50)` returns the interstitial URL; with `Up`, returns the original.

## 6. UI surfaces

- [ ] 6.1 In [lib/screens/settings.dart](../../../lib/screens/settings.dart) per-site Proxy block: add a `SwitchListTile` "Route through Tor (Tor)" above the existing proxy type dropdown, gated on `TorService.isAvailable`. When on, hide (don't unmount) the manual fields.
- [ ] 6.2 In [lib/screens/app_settings.dart](../../../lib/screens/app_settings.dart): add `ProxyType.TOR` option to the global outbound proxy dropdown (iOS only). Add a "Tor status" card subscribing to `TorService.statusStream` with bootstrap progress bar, current state, "Rebuild circuits" button.
- [ ] 6.3 Show a per-site exit-country hint (small caption under the `useTor` switch) populated via `GETINFO ip-to-country/<exitIP>` once the site has completed at least one fetch under Tor. Update every 30s while site is foregrounded. Skip if Tor not bootstrapped.

## 7. Background task integration

- [ ] 7.1 In [ios/Runner/BackgroundTaskPlugin.swift](../../../ios/Runner/BackgroundTaskPlugin.swift): when starting the `beginBackgroundTask` window for notification sites, query `TorControllerPlugin` for the list of `useTor` refcount holders; if any of them are notification sites, suppress `TorService` idle-stop until the window expires.
- [ ] 7.2 In the `BGAppRefreshTask` handler: before reloading a notification site, if `useTor=true` on that site, await `TorService.maybeStart` reaching `Up` (with the same 90s timeout) and only then trigger the reload.

## 8. Settings backup

- [ ] 8.1 No changes to `kExportedAppPrefs` registry expected — `useTor` rides through `WebViewModel.toJson`/`fromJson`; `ProxyType.TOR` in `globalOutboundProxy` round-trips automatically.
- [ ] 8.2 Regression test in [test/settings_backup_test.dart](../../../test/settings_backup_test.dart): assert that exporting settings with `useTor=true` sites and `globalOutboundProxy.type == TOR` does NOT contain any of: Tor control-cookie bytes, the session SOCKS5 password from `TorService._sessionSecret`, or any other Tor-runtime in-memory state. Title: "Tor secrets never appear in exports (TOR-009)".

## 9. Tests

- [ ] 9.1 `test/tor_service_test.dart`: state machine (start → bootstrap → up → idle-stop debounce), 90s bootstrap timeout, refcount on/off correctness, session secret rotation across instances, `socksFor` username derivation (per-site vs app-global), "never reports 9050" hardcode check.
- [ ] 9.2 `test/outbound_http_tor_test.dart`: `ProxyType.TOR` routes through `TorService.socksFor`, fail-closed when `status != Up`, per-site `useTor` overrides manual address, DEFAULT with global TOR uses the `__webspace_app_global__` tag.
- [ ] 9.3 `test/web_view_model_tor_propagation_test.dart`: `useTor` survives `toJson` → `fromJson` round-trip; nested-webview ctor receives `useTor` through the full propagation chain (mirrors the existing per-site-field propagation tests).
- [ ] 9.4 `test/tor_bootstrap_interstitial_test.dart`: navigation hook rewrites pre-bootstrap; auto-resumes on `Up`.
- [ ] 9.5 Manual iOS test matrix in [tasks.md → manual checklist](#10-manual-test-matrix-ios) below.

## 10. Manual test matrix (iOS)

- [ ] 10.1 Two `useTor` sites loaded concurrently in container mode show distinct exit IPs at `check.torproject.org`; refresh both — each gets stable circuit until "Rebuild circuits" tapped.
- [ ] 10.2 Toggle `useTor` off on one site mid-session — that site's next navigation routes direct (or through manual proxy if set); the other `useTor` site is unaffected.
- [ ] 10.3 Force-quit and relaunch with a `useTor` site set — first navigation shows the bootstrap interstitial, auto-resumes when ready.
- [ ] 10.4 Toggle airplane mode mid-bootstrap — surfaces the `Errored("could not connect to any directory authority")` state with a working Retry button.
- [ ] 10.5 Notification site + `useTor`: push notification arrives during a 30s grace window (test by minimising the app at a known message-firing site).
- [ ] 10.6 Disable `useTor` on the last site; observe Tor stays up for 60s, then shuts down (check via `nettop`-on-Mac while the iOS device is tethered).
- [ ] 10.7 Settings export → import on a fresh install: `useTor` flags and `globalOutboundProxy.type == TOR` survive; no Tor cookie / password material in the export JSON (`grep -i` on the file).

## 11. Release prep

- [ ] 11.1 Update App Store Connect encryption documentation to match Onion Browser's exemption claim (open-source crypto, end-user data protection, not exporting keys). No `Info.plist` change.
- [ ] 11.2 Update fastlane iOS release notes in `fastlane/metadata/ios/en-US/release_notes.txt` (per Fastlane size limits) describing the new toggle. Run `scripts/validate_fastlane_metadata.sh` if any Android sibling notes also touched.
- [ ] 11.3 Document the binary-size growth (~15 MB iOS IPA) in the PR description and the OpenSpec change archive note.
- [ ] 11.4 Cross-link the new spec from CLAUDE.md's openspec slug table: add `tor-proxy | embedded Tor on iOS; per-site SOCKS5 isolation`.
