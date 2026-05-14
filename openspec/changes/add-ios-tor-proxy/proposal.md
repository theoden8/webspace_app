## Why

iOS is hostile to system-wide proxying: there is no Orbot equivalent that
transparently shovels every app's traffic through Tor, and Apple's
Network.framework rejects loopback proxies set on `WKWebsiteDataStore`
unless something is actually listening on that port. Users who want
Tor-routed browsing on iOS today have to install a separate onion
browser, which loses every WebSpace privacy layer (container isolation,
ClearURLs, content blocker, ETP fingerprinting shim, per-site language
and geolocation).

The plumbing for per-site SOCKS5 already works end-to-end on iOS 17+
(`proxy` + `ip-leakage` specs). The missing piece is a SOCKS5 endpoint
on-device. Embedding Tor.framework (the same library Onion Browser
ships) gets us one: a managed `127.0.0.1:<random>` SOCKS5 listener with
stream isolation, with no entitlement extensions needed.

## What Changes

- New iOS-only `TorService` (Dart) wrapping a Swift `TorController`
  plugin that owns a `TorThread` + `TorConfiguration` from
  Tor.framework. Lifecycle: lazy-start when any site is configured with
  `useTor=true` or the global outbound proxy is set to "Tor"; idle-stop
  after a debounce when no site needs it.
- Per-site `useTor: bool` field on `WebViewModel`. When true, the
  effective proxy is forced to `SOCKS5 127.0.0.1:<torPort>` with
  `username=<siteId>` and a random per-session password so Tor's
  `IsolateSOCKSAuth` builds a separate circuit per site (each site gets
  its own exit IP, no cross-site linkability).
- Global outbound proxy gains a new `ProxyType.TOR` value that resolves
  the same way per-site. App-global Dart traffic (DNS blocklist,
  ClearURLs, content-blocker downloads, OSM tiles) follows the global
  setting.
- Tor status surface: a small status card in App Settings → Tor
  (bootstrap %, current circuit count, "rebuild circuits" button) and a
  per-site `useTor` switch in the existing site Proxy block that hides
  the manual `host:port` / `username` / `password` fields when on.
- iOS background contract: when the app pauses, Tor keeps running for
  the existing notification grace window
  ([`BackgroundTaskService`](../../specs/per-site-containers/spec.md))
  if any notification site has `useTor=true`; otherwise it shuts down
  cleanly to free the loopback port.
- `Info.plist`: no new entitlements (`NSAppTransportSecurity` already
  permits loopback HTTP for the fork's debugger bridge); a privacy
  manifest entry for the Tor dependency's reasons.
- Linker: `Tor.framework` + `OpenSSL.framework` + `libevent.framework`
  vendored under `ios/Frameworks/`, integrated via a Cocoapods podspec
  pulling from the upstream `iCepa/Tor.framework` tag.
- Dart-side: extend `outboundHttp.clientFor` so that
  `ProxyType.TOR` routes through the running `TorService.socksEndpoint`
  with the same stream-isolation auth, and fails closed exactly like
  malformed SOCKS5 today when Tor is not bootstrapped yet.
- **NOT** included in this change (deferred):
  - Android (already covered by Orbot's `VpnService` and an existing
    SOCKS5 proxy at `127.0.0.1:9050`; user can point the existing
    per-site SOCKS5 at it).
  - macOS (technically the same Tor.framework works; ship after iOS
    proves out).
  - Linux (rely on system `tor` package).
  - Tor Bridges / Pluggable Transports UI (obfs4, snowflake). Initial
    cut uses default consensus directories; bridge entry is a follow-up.
  - Hidden-service `.onion` browsing UX polish (works incidentally
    once SOCKS5 routes through Tor — addressed by a future
    `tor-onion-services` change).

## Capabilities

### New Capabilities
- `tor-proxy`: embedded Tor runtime on iOS providing a loopback SOCKS5
  endpoint with per-site stream isolation, lifecycle managed against
  the set of sites/global settings requesting it, bootstrap and circuit
  status surfaced in App Settings, and integrated with the existing
  background-task grace window for notification sites.

### Modified Capabilities
- `proxy`: add `ProxyType.TOR`, per-site `useTor` field, behavior when
  Tor is not yet bootstrapped (fail-closed at the SOCKS5 seam, native
  webview shows a Tor-bootstrap interstitial instead of a connection
  error), and the rule that `useTor=true` overrides the manual
  `address`/`username`/`password` fields without erasing them.
- `ip-leakage`: stream-isolation contract (every per-site Tor circuit
  is partitioned by `siteId`, never shared across sites), reaffirm the
  DNS posture (Tor's `SocksPort … IsolateDestAddr` plus the existing
  `socks5_proxy` remote-resolution idiom keep the local resolver out of
  the loop), and a new row in the LEAK-007 coverage matrix for the
  Tor-runtime control port (loopback-only, no external traffic).

## Impact

- **iOS project**:
  - `ios/Podfile`: add `pod 'Tor', '~> 408.10'` (or whatever
    `iCepa/Tor.framework` tag is current at implementation time).
  - `ios/Runner/TorControllerPlugin.swift`: new Flutter method-channel
    plugin (`org.codeberg.theoden8.webspace/tor`) exposing `start`,
    `stop`, `status`, `rebuildCircuits`, `socksEndpoint`, plus a
    bootstrap-progress event channel.
  - `Info.plist`: no new entitlements; add `NSPrivacyAccessedAPITypes`
    rows that Tor.framework requires (file-timestamp / disk-space, per
    Apple's required-reasons API list).
  - Background task: extend the existing
    `BackgroundTaskService` grace window so Tor's shutdown defers if a
    `useTor` notification site is loaded.
- **Flutter code**:
  - `lib/services/tor_service.dart`: Dart wrapper, manages lifecycle,
    exposes `Stream<TorStatus>` (`booting | bootstrapping(pct) | up |
    error(msg) | stopped`), per-site SOCKS auth, and idle shutdown.
  - `lib/settings/proxy.dart`: add `ProxyType.TOR`.
  - `lib/services/outbound_http.dart`: route `ProxyType.TOR` through
    the running Tor endpoint with stream-isolation username.
  - `lib/services/webview.dart`: `_userProxyToInappProxy` translates
    `useTor=true` into the same SOCKS5 map the fork's
    `WKWebsiteDataStore.proxyConfigurations` already consumes.
  - `lib/web_view_model.dart`: per-site `useTor` field +
    `WebViewConfig` propagation (must also reach
    `InAppWebViewScreen`'s nested webview ctor per CLAUDE.md "Per-site
    settings MUST apply to nested webviews" rule).
  - `lib/screens/settings.dart`: per-site Tor switch within the
    existing Proxy block.
  - `lib/screens/app_settings.dart`: Tor status card under "Outbound
    proxy", `ProxyType.TOR` option, "rebuild circuits" action.
  - `lib/main.dart`: hook `TorService.maybeStart` after
    `GlobalOutboundProxy.initialize` so any site requesting Tor on
    cold-start has a SOCKS endpoint ready before its webview builds.
- **Settings backup**: `useTor` rides `WebViewModel.toJson`
  automatically (per-site settings rule); `ProxyType.TOR` in
  `globalOutboundProxy` round-trips through the existing
  `kExportedAppPrefs` registry without changes.
- **Tests**:
  - Dart unit tests for `TorService` lifecycle (debounced idle stop,
    fail-closed on bootstrap timeout), `outbound_http` Tor branch, and
    `resolveEffectiveProxy` with `ProxyType.TOR`.
  - `test/settings_backup_test.dart` automatic via the registry — no
    edit needed for `ProxyType.TOR`.
  - Manual iOS test matrix: `useTor` site shows distinct exit IP from
    a non-Tor site; switching webspaces while Tor is bootstrapping
    blocks navigation rather than leaking direct; rebuild-circuits
    flips the exit IP within ~10s.
- **F-Droid / Play builds**: change is iOS-only; Android flavors
  (`fdroid`, `fmain`, `fdebug`) are untouched. The platform-aware UI
  rule hides the Tor switch on platforms where `TorService` is
  unavailable.
- **Binary size**: Tor.framework + OpenSSL + libevent adds ~12-18 MB
  to the iOS IPA. Acceptable for the privacy benefit; will surface in
  the release changelog.
- **Export compliance**: Tor.framework uses strong cryptography;
  WebSpace's iOS export-compliance declaration in App Store Connect
  must be updated to "uses exempt encryption" (matches Onion Browser's
  declaration) before submission.
