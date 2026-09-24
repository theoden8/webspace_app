# Status note (2026-09-20)

Read this before working the boxes below: **the open items are not a to-do
list in their current form.** Two design drifts and one CI decision happened
after they were written, and the list did not follow.

## Update (2026-09-23): the note above has been worked, not just written

Everything the 09-20 note diagnosed is now applied to the boxes rather than
described above them. What changed:

* **8.2 is closed**, and it was the one genuine gap.
  [test/tor_secrets_export_test.dart](../../../test/tor_secrets_export_test.dart)
  proves the session secret and the per-site SOCKS credential are reachable
  through `socksFor`, then asserts a backup carries neither, nor tor's
  loopback port.
* **9.1, 9.3, 9.4 and 11.4 are ticked** against the files that actually cover
  them. 9.3 was marked "verify before closing": verified — the nested chain is
  gated generically over `LaunchUrlFunc`'s parameter list, and `proxySettings`
  is named in the posture set, so Tor is covered by construction rather than
  by a Tor-specific copy.
* **5.2 and 5.3 are struck as superseded**, not left looking pending. The
  interstitial-URL design they describe was replaced by `deferInitialLoadForProxy`
  and the widget-level placeholder.
* **`useTor` is gone from the wording** of 7.1, 7.2, 8.1, 9.2 and 10.x. They
  now say `proxySettings.type == ProxyType.TOR`, which is the field that
  exists.

What is left is 17 items and none of them is a code gap CI can close: 6.3
(exit-country hint), 7.1/7.2 (background refresh under Tor), 6b.10 and
9.5/10.x (on-device and manual by construction), and 11.1a–11.3 (release
paperwork).

**The macOS proxy-tier section below is spent.** The skipped switch arm it
describes no longer exists: #603 rewrote that file to one arm per guarantee,
and BUG-014's conclusion is that per-site proxies on Apple work — the void
instrument was the arms' destination, not the binding. What remains of the
Tor runtime's own trouble is on iOS, in
[docs/bugs/013-tor-never-connects.md](../../../docs/bugs/013-tor-never-connects.md),
where the macOS tier now bootstraps to 100% and the iOS half is unmeasured.

## The list is written against a `useTor` boolean that does not exist

Every task phrased "when `useTor=true`" (5.2, 5.3, 7.1, 7.2, 8.2, 9.3, 10.1,
10.2, 10.6, 10.7) describes a per-site boolean. The implementation has none:
Tor rides the existing per-site `proxySettings` as `ProxyType.TOR`
(`lib/web_view_model.dart`, `resolveEffectiveProxy`). `useTor` appears nowhere
in `lib/`, nowhere in `test/`, and nowhere in this change's own
`specs/tor-proxy/spec.md` -- the spec moved on and `tasks.md` did not.
Rephrase against `proxySettings.type == ProxyType.TOR` before working any of
them.

## The bootstrap interstitial was replaced, not built

5.2, 5.3 and 9.4 describe rewriting a pre-bootstrap navigation to
`webspace://tor-bootstrap?next=...`. That scheme exists nowhere in `lib/`. The
shipped mechanism is `deferInitialLoadForProxy`
([lib/services/webview.dart](../../../lib/services/webview.dart)): the initial
load is held until the proxy is usable, rather than redirected through an
interstitial URL. These three describe a superseded approach.

## Several "open" test tasks are done under other filenames

`tasks.md` names three files that were never created, while 14 `test/tor_*.dart`
files exist. Checked:

| task | names | actually covered by | state |
|------|-------|--------------------|-------|
| 9.1 | `test/tor_service_test.dart` | `tor_engine_test.dart` -- TOR-002 lifecycle (first holder starts, second does not restart, same reason counts once, debounce cancel, `syncHolders`), TOR-013 bootstrap timeout, TOR-003 stream isolation | **done** |
| 9.4 | `test/tor_bootstrap_interstitial_test.dart` | `tor_bootstrap_placeholder_test.dart`, `tor_ui_states_test.dart` -- against the defer mechanism, not the interstitial | **done, different design** |
| 9.3 | `test/web_view_model_tor_propagation_test.dart` | nothing by that name; per-site field propagation is covered generically by `test/nested_webview_field_parity_test.dart` | **verify before closing** |
| 11.4 | CLAUDE.md slug-table cross-link | [CLAUDE.md](../../../CLAUDE.md) line ~251 carries the `tor-proxy *(change)*` row | **done** |

## One genuinely open gap, and it is a secrets gap

**8.2 is not done.** `test/settings_backup_test.dart` contains no Tor coverage
at all -- no `TOR-009`, no session-secret assertion, no control-cookie
assertion. The rule in CLAUDE.md ("Adding a new credential / secret") wants a
regression test asserting the secret never appears in
`SettingsBackupService.exportToJson(...)`. Write it against
`ProxyType.TOR` + `TorService`'s session secret, not against `useTor`.

The 6b.10 and 10.x items are on-device/manual by construction and cannot close
in CI.

## The macOS proxy tier on the Tor PR is disabled, deliberately

`integration_test/proxy_binding_test.dart`'s switch arm ("a second site
switched to another proxy uses the new one") is `skip: true` on #597 by
request, so the Tor work can land while BUG-014 is open. It is not a flake:
in run 35513419116 the arm before it proxied in the same app process, so the
second store going direct is a real reading of a real leak. The question stays
under measurement on #603 (`proxy_matrix_test`). Re-enable when BUG-014 has a
fix or the app fails closed (LEAK-003). Lineage:
[docs/bugs/014-per-site-setting-dropped-at-the-native-seam.md](../../../docs/bugs/014-per-site-setting-dropped-at-the-native-seam.md).

---

## 1. Native iOS plugin (Tor.framework integration)

- [x] 1.1 Added `pod 'Tor', '409.11.2'` (exact version, not `~>`) to `ios/Podfile`. The podspec's `prepare_command` already verifies the downloaded `tor.xcframework` against pinned sha256 digests, so no extra CI checksum step is needed. Pod requires iOS 15.0, which the Podfile floor already is.
- [x] 1.2 Create `ios/Runner/TorControllerPlugin.swift` registering `FlutterMethodChannel <bundleId>/tor` and `FlutterEventChannel <bundleId>/tor/events`. Register in `AppDelegate.swift` alongside `BackgroundTaskPlugin`.
- [x] 1.3 Implement `start()` — builds a `TorConfiguration` with `SocksPort auto IsolateSOCKSAuth IsolateDestAddr`, control-port cookie auth, ephemeral `DataDirectory` under `NSCachesDirectory/Tor/`, spawns `TorThread`, subscribes to control-port `BOOTSTRAP` events.
- [x] 1.4 Implement `status()` — returns `{state, bootstrapPct, socksHost, socksPort}` synchronously; emits the same shape via the event channel as state changes.
- [x] 1.5 Implement `rebuildCircuits()` — sends `SIGNAL NEWNYM` via the control port. Rate-limit at the plugin layer (no-op if last NEWNYM was less than 10s ago).
- [x] 1.6 Implement `stop()` — graceful shutdown via `TorThread.cancel()`, awaits termination with a 5s timeout then force-exits the thread. Clears in-memory port info.
- [x] 1.7 Create `ios/Runner/PrivacyInfo.xcprivacy` (the repo has no privacy manifest today) and add it to the `Runner` target's Copy Bundle Resources. Declare the `NSPrivacyAccessedAPITypes` rows for the required-reason APIs the *app* calls, with the reason codes verified against Apple's current required-reasons list at implementation time rather than copied from this document. Do NOT put `NSPrivacyAccessedAPITypes` in `Info.plist` — Apple does not read it there (TOR-011).
- [x] 1.8 Confirmed: the pinned Tor pod ships **no** `PrivacyInfo.xcprivacy` (checked the upstream tree). Its required-reason usage is declared from the app's manifest as the only available option; raise the gap upstream. If it does not, raise it upstream and record the gap in the change; do not declare the pod's API usage from the app's manifest.

## 2. Dart Tor service

- [x] 2.1 Add `lib/services/tor_service.dart`: `TorService.instance`, `TorStatus` sealed class hierarchy (`Stopped`, `Starting`, `Bootstrapping(pct)`, `Up`, `Errored(msg)`), `Stream<TorStatus> statusStream` (broadcast), `bool isAvailable` (returns `Platform.isIOS` initially).
- [x] 2.2 Implement refcount + 60s debounce timer: `maybeStart(reason)`, `release(reason)`, internal `_count` keyed by reason string for diagnostics; idle-stop timer scheduled when `_count == 0`, canceled on reactivation.
- [x] 2.3 Implement `socksFor({String? siteId, bool appGlobal = false})` returning a `UserProxySettings` with type SOCKS5, address from current `socksEndpoint`, username = `siteId ?? '__webspace_app_global__'`, password = `_sessionSecret` (random 32-byte hex generated once per instance).
- [x] 2.4 Implement `rebuildCircuits()` — invokes the plugin method, surfaces any rate-limit response back to the caller (no-op snackbar in UI).
- [x] 2.5 Wire the plugin's event channel to `statusStream`; map Swift state codes to Dart `TorStatus` cases.
- [x] 2.6 Bootstrap timeout: if `Bootstrapping(*)` for >90s without reaching `Up`, transition to `Errored("bootstrap timed out")` and stop the underlying thread.
- [x] 2.7 Stub `TorService` on non-iOS platforms — every method is a no-op, `isAvailable == false`, `statusStream` emits only `Stopped`. No native plugin reference at all on Android/macOS/Linux builds.

## 3. Per-site Tor selection (`ProxyType.TOR`)

Superseded: the original plan added a parallel `useTor` bool. It encoded
the same state as `ProxyType.TOR` and would have needed its own copy of
the nested-webview propagation chain. See PROXY-020 for the reasoning.

- [x] 3.1 Append `ProxyType.TOR` to the enum; `UserProxySettings.fromJson` decodes an unknown index to `DEFAULT` instead of throwing (rollback safety).
- [x] 3.2 `WebViewModel.outboundProxySettings` returns a `siteId`-tagged *copy* under TOR, leaving the stored manual address/credentials intact. Every per-site outbound seam (9 call sites in `main.dart`, the `WebViewConfig`, both nested `launchUrlFunc` calls) passes the tagged copy, so nested webviews inherit isolation without a second propagation chain.
- [x] 3.3 `_syncTorHolders` in `main.dart` reconciles the refcount from the site list plus the global proxy, called from `_saveWebViewModels` (the funnel every edit/import/delete passes through) and once at startup after the model load.
- [x] 3.4 Deleted sites drop out of the holder set automatically — `syncHolders` diffs the whole set rather than tracking deltas per call site.

## 4. Proxy resolution and outbound HTTP

- [x] 4.1 Add `ProxyType.TOR` to the enum in [lib/settings/proxy.dart](../../../lib/settings/proxy.dart). Serialize as a new integer value (append; do NOT renumber existing values — would break backups).
- [x] 4.2 In [lib/services/outbound_http.dart](../../../lib/services/outbound_http.dart): extend `clientFor` so `ProxyType.TOR` (and `useTor=true`) resolves via `TorService.instance.socksFor(...)`; the returned `UserProxySettings` is then handled by the existing SOCKS5 branch (no duplicate `socks5_proxy` plumbing).
- [x] 4.3 In `resolveEffectiveProxy`: per-site `useTor=true` wins over both manual per-site proxy and global TOR. Per-site DEFAULT with `globalOutboundProxy.type == TOR` resolves with the `__webspace_app_global__` isolation tag, NOT the site's `siteId`.
- [x] 4.4 Fail-closed: when `useTor` or `TOR` is in play and `TorService.status != Up`, return `OutboundClientBlocked` from `clientFor`. Tests using `RecordingFactory` assert no fallback `http.Client()` is constructed.
- [x] 4.5 In [lib/services/webview.dart](../../../lib/services/webview.dart) `_userProxyToInappProxy`: when `useTor=true` or type `TOR`, fetch from `TorService.instance.socksFor(siteId: ...)` and emit the SOCKS5 map the fork's iOS native side consumes.

## 5. Bootstrap interstitial

- [x] 5.1 Add a Flutter screen `lib/screens/tor_bootstrap.dart` that subscribes to `TorService.statusStream`, renders a determinate progress bar (`Bootstrapping(pct)`), an error + Retry button (`Errored`), and on `Up` calls `Navigator.pushReplacement` with the `next` URL.
- ~~5.2 Rewrite a pre-bootstrap navigation to `webspace://tor-bootstrap?next=<encoded>` from the navigation policy hook.~~ **Superseded.** That scheme exists nowhere in `lib/`. The shipped mechanism holds the load instead of redirecting it: `deferInitialLoadForProxy` ([lib/services/webview.dart](../../../lib/services/webview.dart)) plus the widget-level `TorBootstrapPlaceholder`, which TOR-008 specifies. A redirect would have put the site's own URL in a query string and taken the user through a navigation they did not make.
- ~~5.3 Unit test for that rewrite.~~ **Superseded with 5.2.** What replaced it is 9.4.

## 6. UI surfaces

- [x] 6.0 Gate the whole feature behind developer mode (DEVTOOLS-010) until TOR-013's bootstrap surface lands: `TorService.isAvailable` is the conjunction of the platform gate and `DeveloperModeService.instance.enabled`, every start path re-checks it, `socksFor` returns null with it shut, and turning the flag off releases the holders already taken. The gate deliberately sits on `TorService` rather than the runtime or engine, which stay pure platform questions for their fake-backed tests.

- [x] 6.1 In [lib/screens/settings.dart](../../../lib/screens/settings.dart) per-site Proxy block: offer `ProxyType.TOR` in the proxy type dropdown, gated on `TorService.isAvailable`, and hide the manual address/credential fields under it without overwriting what they hold. Shipped as a dropdown value rather than the planned separate switch — PROXY-020 records why a second flag was dropped.
- [x] 6.2a In [lib/screens/app_settings.dart](../../../lib/screens/app_settings.dart): add `ProxyType.TOR` to the global outbound proxy dropdown, on the same `TorService.isAvailable` gate, with the address validator exempting it.
- [x] 6.2b Add a "Tor status" card subscribing to `TorService.statusStream`: bootstrap progress bar, current state, "Rebuild circuits" button. Nothing renders `TorStatus` today — `bootstrapPct`, the SOCKS endpoint and `lastError` all reach `TorEngine` and stop there. Pairs with the 5.x interstitial as the TOR-013 surface.
- [x] 6.2c Exit-country **picker** for TOR-014. A shortlist of the countries that carry a durable share of exit capacity, not all of ISO 3166: `StrictNodes` makes a pin with no usable exit a dead end, so offering every code would be offering mostly dead ends. Names are endonyms in a const Dart map, the same trick `kLanguageNativeNames` uses for the language picker, which keeps ~40 country names out of 67 ARB files; the ISO code rides alongside so an unfamiliar endonym is still identifiable. A stored pin outside the shortlist keeps its bare code rather than reading as unpinned.
- [x] 6.2d GeoIP for TOR-014, which the pin never had: tor was resolving `{br}` against no table, found no relay, and the site kept loading over a pooled connection to its old exit. The table is downloaded on the device through Tor (onion first) into the app cache, never bundled (LICENSE-002), loaded by `SETCONF GeoIPFile` before `ExitNodes`, and every exit-capable circuit is closed after a pin change. The engine holds `up` back until the pin lands; a failed download is `exitCountryData`.
- [ ] 6.3 Show a per-site exit-country *hint* — what country the circuit actually left from, distinct from 6.2c's pin — populated via `GETINFO ip-to-country/<exitIP>` once the site has completed at least one fetch under Tor. Update every 30s while site is foregrounded. Skip if Tor not bootstrapped.

## 6b. Failure classification and bridges (TOR-015, TOR-016, TOR-017)

- [x] 6b.1 `lib/services/tor_failure.dart`: classify tor's output into `offline`, `censored`, `clockSkew`, `exitPolicy`, `controlChannel`, `bootstrapTimeout`, `runtime`, each with its own copy, icon and transience. The raw message stays alongside, so a misclassification is visible rather than hidden.
- [x] 6b.2 `TorEngine.restart()`: stop then start keeping the holder set. `acquire` returns early whenever a holder exists — which it always does for a site pinned to TOR — so the Retry button was inert routed through it.
- [x] 6b.3 `lib/services/tor_bridges.dart`: transports, verbatim bridge lines, per-error parse failures, and `torBridgeOptions` generating the torrc pairs. Pure Dart, so the Swift side applies an already-tested configuration.
- [x] 6b.4 `TorRuntime.startTransport` / `setTorrcOptions`, applied before every `start` in both `acquire` and `restart`. Options travel as an ordered pair list: `Bridge` repeats per line and a map would keep only the last.
- [x] 6b.5 Built-in snowflake line. IPtProxy's `Controller` defaults every snowflake rendezvous field to empty, so `UseBridges 1` with no `Bridge` line leaves tor with nothing to dial rather than reaching a default.
- [x] 6b.6 `lib/services/tor_bridge_secure_storage.dart` (TOR-017): keystore-backed, outside the export registry by construction. A failed write reports failure rather than claiming saved.
- [x] 6b.7 `lib/services/tor_moat_client.dart`: BridgeDB over Moat, empty solution first so the common case needs no captcha. Wire format verified against the live service — `transport` is a list, the image is JPEG, `challenge` is the transport name.
- [x] 6b.8 `lib/screens/tor_bridge_settings.dart`: toggle, transport picker, verbatim line list, paste with per-error messages, Moat fetch with the LEAK-015 exposure stated above the button, restart-needed notice. Reached from the status card only where `bridgesMayHelp`.
- [x] 6b.9 iOS native: `setTorrcOptions`, `startTransport` and `setExitCountry` handlers in `TorControllerPlugin.swift`; `IPtProxy` 5.5.1 in the Podfile; Go pinned in the Apple CI job, since that pod cross-compiles from source during `pod install`. Bridges reach tor through `TORConfiguration.arguments`, not `options` — the latter is a dictionary and would collapse repeated `Bridge` keys.
- [ ] 6b.10 On-device: obfs4 and snowflake each bootstrap on a network that blocks tor directly. Not reachable from CI — no simulator can be censored, and the transports need a real hostile network to mean anything.

## 6c. Bootstrap observability (TOR-018)

- [x] 6c.1 iOS native: forward `TAG`/`SUMMARY` off every `BOOTSTRAP` status event, hold them beside the percentage, and publish them in the status payload. They were read and dropped before, so `classifyTorFailure`'s `torTag` was always null and every stalled bootstrap classified as a plain timeout.
- [x] 6c.2 iOS native: read `GETINFO status/bootstrap-phase` on attach. Bootstrap starts before the control port answers; a bootstrap that finished during the handshake sends no further event, and the interstitial sat on "Starting" until the 90s timeout.
- [x] 6c.3 iOS native: capture tor's `NOTICE`/`WARN`/`ERR` over the control port and relay them on `.../tor/logs`, with a small native ring so a late Dart subscriber still sees the first lines. `sendCommand` rather than `listenForEvents`, since the framework registers a raw-line observer only there — and `addObserver(forCircuitEstablished:)` is gone for the same reason: it re-sends SETEVENTS and would unsubscribe the log.
- [x] 6c.4 iOS native: the plugin's own lifecycle notes (start, attach, authenticate, SOCKS listener, transports, stop, failures) on the same channel, covering the window tor's log cannot describe.
- [x] 6c.5 `lib/services/tor_service.dart`: decode the phase, pipe the log channel into `LogService` (tor's output sensitive under its own tag, the plugin's notes ordinary), and log every state transition. The bridge is deliberately not on `TorRuntime` — it is not a decision, and every test fake would have to implement it.
- [x] 6c.6 `test/tor_observability_test.dart` and the structural gate `test/js/tor_bootstrap_observability.test.js` (key parity across the seam, channel-name parity, no INFO/DEBUG, no log file on disk).
- [x] 6c.7 iOS native (TOR-019): read `net/listeners/socks` and `status/bootstrap-phase` at attach, before SETEVENTS, and promote the endpoint when bootstrap finishes. Tor.framework hands replies and async events to one observer list, and its GETINFO observer answers the first line it sees: with events already flowing, a bootstrap notice answered the socks read as empty and a finished bootstrap reported "no usable SOCKS listener". The same shape removed the framework's own circuit-established observer, which is why a successful bootstrap could sit on the interstitial until the 90s timeout.
- [x] 6c.8 iOS native (TOR-020, BUG-007 attempt 6): stop asks tor to exit over the control port and hands its thread to an exit watch; start waits for that thread to finish and fails by name rather than constructing a second `TorThread`. A `generation` counter bumped by every start and stop keeps an earlier run's handshake, read or failure from speaking for the current one. Retry, the idle stop and the bootstrap timeout all put a stop and a start seconds apart, and each of them was a crash.
- [x] 6c.9 `ios/RunnerTests/TorControlParsingTests.swift`: the control-port parsers against tor's real output shapes, including the closing quote `getInfoForKeys` trims off a `SUMMARY`. Wired into the RunnerTests target; no CI tier here runs Swift, so it runs in Xcode.
- [x] 6c.10 `lib/widgets/tor_bootstrap.dart`: show tor's raw message under the classified copy, as the status card already does, and let the column scroll instead of overflowing — the interstitial is where a user is left when a site will not load, and the classification is a guess from patterns.
- [x] 6c.11 iOS native (TOR-020, BUG-007 attempt 7): every retirement -- stop and failure alike -- hands the run to an exit watch that asks tor to quit over a control connection it opens itself (port file + cookie + `SIGNAL HALT`, retried while the thread lives). `controller?.disconnect()` reaches nothing when no controller was adopted, which is the state a failed handshake leaves behind, and the orphan then held the process's only tor slot for good: on TestFlight, Retry answered "The previous Tor is still running" forever. `integration_test/tor_test.dart` restarts inside the handshake window to cover it.
- [x] 6c.12 iOS native (TOR-019, BUG-013 attempt 2): the control-port attach is a bounded poll (0.5s x 60) scheduled from the state queue, not 1.0s plus three blocking retries. The old budget was about 1.5 seconds, which fails a cold start on a busy phone and was the first domino: the run failed, and before BUG-007 attempt 7 the tor it left behind made every later start refuse.
- [x] 6c.13 iOS native + UI (TOR-018, BUG-013 attempt 3): tor writes `--Log notice file <dataDir>/tor.log` and the plugin tails it into the app log, replacing the control-port log subscription -- which cannot work on the device that prompted this, where tor never opens a control port at all. The attach notes now say whether the port file exists and whether the thread is executing, and the interstitial renders the last log lines live on both the waiting and the failure screen.

## 6d. macOS runtime and the integration tier (TOR-021)

- [x] 6d.1 Compile `ios/Runner/TorControllerPlugin.swift` from the macOS Runner too, with `#if canImport(FlutterMacOS)` picking the Flutter module. Shared rather than mirrored (which is how `ShortcutsPlugin` does it) because the tier is only worth running if it exercises the code iOS ships. The file stays under the iOS project rather than moving to a neutral directory: iOS is the shipping target, so the cross-directory reference is the macOS one.
- [x] 6d.2 `macos/Podfile`: the same `Tor` and `IPtProxy` pins as iOS, and the macOS 11 floor the Tor pod needs. `MACOSX_DEPLOYMENT_TARGET` follows in the project, and `LSMinimumSystemVersion` derives from it, so 10.15 is no longer supported — stated in docs/releasing-macos.md. The ShareExtension already required 11.0.
- [x] 6d.3 `macos/Runner/AppDelegate.swift` registers the plugin; `MethodChannelTorRuntime.isAvailable` covers both Apple platforms. Developer mode (DEVTOOLS-010) is still what decides whether anything offers Tor, on macOS exactly as on iOS.
- [x] 6d.4 `integration_test/tor_test.dart`: handshake, phase, tor's log and a restart asserted unconditionally; reaching `up` required only under `WEBSPACE_TOR_NETWORK=1`, since that leg needs the Tor network. A failure prints the captured log rather than a timeout.
- [x] 6d.5 CI runs the macOS integration tier with that variable set. Dropping it leaves every other assertion in place.
- [x] 6d.6 Structural gates: same pod pins on both platforms, no target below the Podfile floor, and both Apple targets compiling the one shared source. Mutation-verified — a version skew, a target left at 10.15, and a target that references the file without compiling it each turn the gate red.
- [x] 6d.7 `integration_test/tor_test.dart` pins `{de}`, then `{us}`, on the real tor (TOR-014). The address check.torproject.org sees must fall in the pinned country by the table the pin downloaded, and a silent stream opened under `{de}` must end once `{us}` is in force, while a control stream opened after it outlives the time that took. Required under `WEBSPACE_TOR_NETWORK=1`, like reaching `up`.
- [x] 6d.8 `integration_test/tor_test.dart` opens two sites' streams at once on the real tor and reads `stream-status` over a control connection of its own: they must ride two circuits (TOR-003). The exits are logged, not compared, since two circuits may share an exit relay. The same connection reports, after each exit-country pin, which circuit the check rode and where tor places its exit.

## 7. Background task integration

- [ ] 7.1 In [ios/Runner/BackgroundTaskPlugin.swift](../../../ios/Runner/BackgroundTaskPlugin.swift): when starting the `beginBackgroundTask` window for notification sites, query `TorControllerPlugin` for the refcount holders (sites whose `proxySettings.type == ProxyType.TOR`); if any of them are notification sites, suppress `TorService` idle-stop until the window expires.
- [ ] 7.2 In the `BGAppRefreshTask` handler: before reloading a notification site, if its `proxySettings.type == ProxyType.TOR`, await `TorService.maybeStart` reaching `Up` (with the same 90s timeout) and only then trigger the reload.

## 8. Settings backup

- [x] 8.1 No changes to `kExportedAppPrefs` registry expected — a site's `proxySettings` rides through `WebViewModel.toJson`/`fromJson`, `ProxyType.TOR` included; `ProxyType.TOR` in `globalOutboundProxy` round-trips automatically.
- [x] 8.2 Regression test: [test/tor_secrets_export_test.dart](../../../test/tor_secrets_export_test.dart), "Tor secrets never appear in exports (TOR-009)". Exports a site on `ProxyType.TOR` with a global `ProxyType.TOR` and asserts the file carries neither the session secret nor the per-site SOCKS credential derived from it, nor tor's loopback port. Both needles are proved live first, through `socksFor`, so the absence is a measurement rather than a spelling. Its own file rather than `settings_backup_test.dart`: it needs a fake `TorRuntime` up, which that file has no other use for.

## 9. Tests

- [x] 9.1 Covered by [test/tor_engine_test.dart](../../../test/tor_engine_test.dart) (TOR-002 lifecycle: first holder starts, a second does not restart, one reason counts once, debounce cancel, `syncHolders`; TOR-013 bootstrap timeout; TOR-003 stream isolation) and [test/tor_developer_mode_gate_test.dart](../../../test/tor_developer_mode_gate_test.dart) (the gate, and `socksFor` failing closed behind it). Written against the engine, which is where the policy lives; `tor_service_test.dart` was never created.
- [x] 9.2 `test/outbound_http_tor_test.dart`: `ProxyType.TOR` routes through `TorService.socksFor`, fail-closed when `status != Up`, a per-site `ProxyType.TOR` overrides a manual address, DEFAULT with global TOR uses the `__webspace_app_global__` tag.
- [x] 9.3 Covered generically, which is stronger than a Tor-specific copy would be: [test/nested_webview_field_parity_test.dart](../../../test/nested_webview_field_parity_test.dart) reads `LaunchUrlFunc`'s own parameter list and requires every one to survive each step of the nested chain, and [test/js/nested_webview_posture_parity.test.js](../../../test/js/nested_webview_posture_parity.test.js) names `proxySettings` in the posture set. Tor rides `proxySettings`, so both cover it; the round-trip is `test/settings_backup_test.dart`'s.
- [x] 9.4 Covered against the shipped design rather than 5.2's: [test/tor_bootstrap_placeholder_test.dart](../../../test/tor_bootstrap_placeholder_test.dart) (showing the placeholder starts the runtime and releases it on the way out) and [test/tor_ui_states_test.dart](../../../test/tor_ui_states_test.dart) (every rendered state, each failure kind with its remedy, and the two gates that cannot open).
- [ ] 9.5 Manual iOS test matrix in [tasks.md → manual checklist](#10-manual-test-matrix-ios) below.

## 10. Manual test matrix (iOS)

- [ ] 10.1 Two `ProxyType.TOR` sites loaded concurrently in container mode show distinct exit IPs at `check.torproject.org`; refresh both — each gets stable circuit until "Rebuild circuits" tapped.
- [ ] 10.2 Move one site off `ProxyType.TOR` mid-session — its next navigation routes direct (or through a manual proxy if set); the other Tor site is unaffected.
- [ ] 10.3 Force-quit and relaunch with a `ProxyType.TOR` site set — the first navigation shows the bootstrap placeholder and resumes when the runtime is up.
- [ ] 10.4 Toggle airplane mode mid-bootstrap — surfaces the `Errored("could not connect to any directory authority")` state with a working Retry button.
- [ ] 10.5 Notification site on `ProxyType.TOR`: push notification arrives during a 30s grace window (test by minimising the app at a known message-firing site).
- [ ] 10.6 Move the last site off `ProxyType.TOR`; observe Tor stays up for 60s, then shuts down (check via `nettop`-on-Mac while the iOS device is tethered).
- [ ] 10.7 Settings export → import on a fresh install: per-site `ProxyType.TOR` and `globalOutboundProxy.type == TOR` survive. The secret half is no longer manual — 8.2 asserts it every run.

## 11. Release prep

- [x] 11.0 Structural CI gates in `test/js/ios_compliance_declarations.test.js`: the encryption declaration, the privacy manifest's existence, its absence from `Info.plist`, its presence in Copy Bundle Resources, and no hardcoded 9050. Each verified to fail on its own regression.

- [x] 11.1 Leave `ITSAppUsesNonExemptEncryption` at `false` in `ios/Runner/Info.plist` (TOR-010). Tor changes what cryptography ships, not whether the source is public, and EXPORT-001's exemption is the publicly-available-source one. An earlier revision of this task mandated `true`; that obliges a compliance code Apple issues only after approving documentation, and it blocked every upload with ITMS-90592 until reverted.
- [ ] 11.1a Add the annual BIS self-classification report (due 1 February for the prior calendar year's distributed builds) to the release checklist.
- [ ] 11.1b Draft the App Review notes: what the toggle does, that bootstrap takes 10-30s on first use, and that a restricted network surfaces an explicit error by design (TOR-013).
- [ ] 11.1c Audit UI strings and assets for trademark discipline before submission — descriptive use of "Tor" only, no onion logo, no "Tor" in app name/subtitle/bundle id, no implied Tor Project endorsement (TOR-012).
- [ ] 11.2 Update fastlane iOS release notes in `fastlane/metadata/ios/en-US/release_notes.txt` (per Fastlane size limits) describing the new toggle. Run `scripts/validate_fastlane_metadata.sh` if any Android sibling notes also touched.
- [ ] 11.3 Document the binary-size growth (~15 MB iOS IPA) in the PR description and the OpenSpec change archive note.
- [x] 11.4 [CLAUDE.md](../../../CLAUDE.md) carries the `tor-proxy *(change)*` row in the openspec slug table.
