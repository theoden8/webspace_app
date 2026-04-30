# IP Leakage Coverage Specification

## Purpose

A privacy-focused browser must route every byte of user-identifying network
traffic through the proxy a user has configured. If even one outbound path
bypasses the proxy, the proxy is defeated — a site (or anyone observing the
ISP) can recover the device's real IP via that side channel.

This specification is the **integrity contract** for proxy coverage in
WebSpace. It enumerates every category of outbound network traffic the app
emits and pins down which proxy applies, when fail-closed behavior is
required, and where the WebRTC, DNS, and tile-server side channels are
addressed.

The proxy mechanism itself (per-site UI, types, validation) is documented in
[`openspec/specs/proxy/spec.md`](../proxy/spec.md). The WebRTC side channel
is implemented in [`openspec/specs/per-site-location/spec.md`](../per-site-location/spec.md);
this spec ties it into the broader IP-leakage threat model.

## Status

- **Date**: 2026-04-25
- **Status**: Implemented

---

## Threat Model

The defended traffic categories are:

1. **Webview HTTP(S) navigation** — top-frame and subframe page loads, AJAX,
   `fetch`, `<img>`, `<script>`, etc. Routed through the native webview.
2. **Per-site Dart-side outbound HTTP** — favicon discovery (DuckDuckGo,
   Google, the site's own HTML), per-site downloads (HTTP / data / blob
   schemes), user-script remote fetches and `window.__wsFetch()` resource
   fetches. Initiated from Dart, must respect the *site's* proxy.
3. **App-global Dart-side outbound HTTP** — DNS blocklist downloads, ClearURLs
   rules, content-blocker filter lists, LocalCDN catalog, OSM map tiles in
   the location picker. Initiated from Dart with no site context, must
   respect the *app-global* outbound proxy.
4. **WebRTC ICE / STUN** — bypasses HTTP(S)/SOCKS proxies in Chromium and
   has historically leaked the device's public IP even through Tor.
5. **DNS resolution** — hostname lookups for any of the above can leak to
   the local resolver if the proxy doesn't tunnel them.

Out of scope (documented as gaps):

- IP-based geolocation by the *server* once the proxy succeeds.
- The user's choice of proxy server itself (we rely on the user not
  picking a malicious proxy).

---

## Requirements

### Requirement: LEAK-001 - Proxy precedence ladder

Every per-site outbound call SHALL resolve through a deterministic
precedence ladder: **explicit per-site override → app-global outbound proxy
→ system / direct**. The implementation lives in `resolveEffectiveProxy`
in [`lib/services/outbound_http.dart`](../../lib/services/outbound_http.dart).

#### Scenario: Per-site DEFAULT inherits global

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy type `DEFAULT`
**When** a per-site Dart-side outbound call originates from "Acme"
**Then** the call routes through `HTTP 10.0.0.1:8080`

#### Scenario: Per-site explicit override wins

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy `SOCKS5 127.0.0.1:9050`
**When** a per-site Dart-side outbound call originates from "Acme"
**Then** the call attempts SOCKS5 (not the global)
**And** the global is **not** silently substituted

#### Scenario: Webview honors the same precedence

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has proxy type `DEFAULT`
**When** the webview for "Acme" is created or reconfigured
**Then** `ProxyController.setProxyOverride` is invoked with `HTTP 10.0.0.1:8080`

---

### Requirement: LEAK-002 - Single Dart-side outbound seam

Every Dart-side outbound HTTP call that may carry user-identifying traffic SHALL go through [`outboundHttp.clientFor(...)`](../../lib/services/outbound_http.dart), and new code MUST NOT call `http.get(...)` (or instantiate a raw `http.Client` / `HttpClient`) directly for network-bound URLs.

The seam is testable: tests replace the global `outboundHttp` factory with
a recording fake (see `test/outbound_http_test.dart` and
`test/outbound_http_call_sites_test.dart`).

#### Scenario: Per-site favicon fetch passes per-site proxy

**Given** site "Acme" has proxy `HTTP 10.0.0.1:8080`
**When** the favicon stream / SVG fetch / favicon-package finder runs for
"Acme"'s URL
**Then** the recording fake observes `clientFor(HTTP 10.0.0.1:8080)`
**And** no direct `http.Client()` was constructed in the call path

#### Scenario: App-global download passes global proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**When** `ClearUrlService.downloadRules` / `DnsBlockService.downloadList` /
`ContentBlockerService.downloadList` / `LocalCdnService._downloadAndCache`
runs
**Then** the recording fake observes `clientFor(HTTP 10.0.0.1:8080)`

#### Scenario: OSM map tiles pass global proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**When** the user opens the location picker and taps "Load map"
**Then** the picker constructs a `NetworkTileProvider` whose `httpClient`
came from `outboundHttp.clientFor(HTTP 10.0.0.1:8080)`
**And** every subsequent tile request goes through that client

---

### Requirement: LEAK-003 - SOCKS5 tunneling and fail-closed posture

Every Dart-side outbound seam SHALL route SOCKS5 traffic through the [`socks5_proxy`](https://pub.dev/packages/socks5_proxy) package's TCP tunnel — both the destination's TCP connection and its hostname resolution travel through the SOCKS5 server, so the local resolver never sees the user's destination — and SHALL fail-closed (skip the request entirely, never fall back to a direct connection) when the proxy is malformed or otherwise un-tunnelable, since falling back would leak the device IP to the very party the user picked the proxy to hide it from.

Webview navigation continues to use SOCKS5 via its native channel — the
patched iOS / macOS plugins' `WKWebsiteDataStore.proxyConfigurations` and
Android's `inapp.ProxyController` — independently of the Dart-side path.

#### Scenario: SOCKS5 favicon fetch tunnels through the SOCKS5 server

**Given** site "Acme" has proxy `SOCKS5 127.0.0.1:9050`
**When** the favicon stream runs for "Acme"
**Then** `outboundHttp.clientFor` returns `OutboundClientReady`
**And** the resulting `http.Client`'s `connectionFactory` opens a TCP
connection to `127.0.0.1:9050`
**And** the destination hostname is sent to the SOCKS5 server (not
resolved locally)

#### Scenario: SOCKS5 download tunnels through the SOCKS5 server

**Given** site "Acme" has proxy `SOCKS5 127.0.0.1:9050`
**When** the user initiates an HTTP download from a page on "Acme"
**Then** `DownloadEngine.fetch` opens its TCP connection via the SOCKS5
tunnel
**And** the response body is delivered through the tunnel

#### Scenario: SOCKS5 with a malformed address fails closed

**Given** site "Acme" has proxy `SOCKS5 not-a-valid-address`
**When** the favicon stream runs for "Acme"
**Then** `outboundHttp.clientFor` returns `OutboundClientBlocked`
**And** the favicon callbacks complete without ever opening a TCP socket
**And** no fallback to a direct `http.Client` is attempted

---

### Requirement: LEAK-004 - Global outbound proxy persistence

The app-global outbound proxy SHALL be persisted under the SharedPreferences
key `globalOutboundProxy` as a JSON-encoded `UserProxySettings`. The key
SHALL be registered in `kExportedAppPrefs` so it round-trips through
settings backup / restore. The in-memory cache (`GlobalOutboundProxy.current`)
SHALL be initialized at app startup before any service that may emit
outbound traffic runs.

#### Scenario: Initialize at startup

**Given** the app is starting up
**When** `main()` runs
**Then** `GlobalOutboundProxy.initialize()` is awaited *before* `runApp`
**And** before any background download (DNS blocklist, etc.) is permitted
to start

#### Scenario: Update propagates immediately

**Given** the user changes "Outbound proxy" in app settings
**When** `GlobalOutboundProxy.update(...)` returns
**Then** subsequent calls to `outboundHttp.clientFor(...)` for per-site
DEFAULT and app-global services use the new proxy
**And** the change is persisted to SharedPreferences

#### Scenario: Backup round-trip

**Given** a settings backup containing
`globalPrefs.globalOutboundProxy = '{"type":2,"address":"127.0.0.1:9050",...}'`
(SOCKS5)
**When** the user imports the backup
**Then** `GlobalOutboundProxy.current` reflects SOCKS5 127.0.0.1:9050
**And** the existing `settings_backup_test.dart` integrity test passes
without modification

---

### Requirement: LEAK-005 - WebRTC lockdown ties into proxy threat model

The per-site `webRtcPolicy` (documented in [LOC-004](../per-site-location/spec.md)) MUST be treated as part of the IP-leakage defense, not only the geolocation defense, because WebRTC `RTCPeerConnection` + STUN bypasses HTTP(S) and SOCKS5 proxies in Chromium and would otherwise expose the device IP through the very channel the user picked the proxy to hide.

The recommended posture for users behind a proxy is:
- **`webRtcPolicy = relayOnly`** for sites that need WebRTC (video chat,
  P2P) — strips host/srflx candidates, leaves only TURN/relay.
- **`webRtcPolicy = disabled`** for sites that don't legitimately need
  WebRTC — neuters `RTCPeerConnection` entirely.

#### Scenario: Default policy with proxy is a documented gap

**Given** the user has configured a global SOCKS5 proxy
**And** site "Acme" has `webRtcPolicy = defaultPolicy` (the default)
**When** the user navigates to a STUN-fingerprinting page on "Acme"
**Then** WebRTC may expose the device IP **— this is a known gap**
**And** the per-site settings UI surfaces a hint encouraging
`relayOnly` or `disabled` when a proxy is configured

#### Scenario: relayOnly stops srflx leak

**Given** `webRtcPolicy = relayOnly` on site "Acme"
**And** "Acme"'s page calls `RTCPeerConnection().createOffer()`
**Then** the SDP delivered to `setLocalDescription` contains only
`typ relay` candidate lines (host/srflx stripped)
**And** the final ICE config has `iceTransportPolicy = 'relay'`

#### Scenario: disabled blocks construction

**Given** `webRtcPolicy = disabled` on site "Acme"
**When** "Acme" evaluates `new RTCPeerConnection()`
**Then** the constructor throws `Error('WebRTC disabled')`

(See [LOC-004](../per-site-location/spec.md) for the JS-shim implementation
details and nested-iframe coverage.)

---

### Requirement: LEAK-006 - DNS leakage posture

The implementation MUST NOT emit local DNS lookups on the user's behalf for any Dart-side outbound call once a non-DEFAULT proxy is resolved. Under HTTP/HTTPS proxies, `dart:io`'s `CONNECT host:port` flow already keeps the local resolver out of the loop. Under SOCKS5, the destination hostname is sent to the SOCKS5 server with `InternetAddressType.unix` (the [`socks5_proxy`](https://pub.dev/packages/socks5_proxy) package's idiom for "don't pre-resolve"), so the SOCKS5 server resolves it — matches Tor's `dns_proxy` semantics.

For *webview* navigation, the platform webview does the right thing on
Android (HTTP/HTTPS) and iOS — the proxy receives the hostname and the
local resolver is bypassed. SOCKS5 in Android WebView resolves remotely.

This requirement is informational — there is no "do" here, just a
documented gap that the implementation already avoids leaking through.

#### Scenario: HTTP proxy + Dart-side fetch — no DNS leak

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**When** a per-site favicon fetch runs for `https://example.com/favicon.ico`
**Then** `dart:io` issues `CONNECT example.com:443` to the proxy
**And** the local resolver is **not** asked to resolve `example.com`

#### Scenario: SOCKS5 + Dart-side fetch — no DNS leak

**Given** the app-global outbound proxy is `SOCKS5 127.0.0.1:9050`
**When** any Dart-side outbound seam connects to a destination
**Then** the destination hostname is sent through the SOCKS5 server
**And** the local resolver is **not** asked to resolve it

---

### Requirement: LEAK-007 - Coverage matrix

The proxy-coverage matrix below SHALL be kept in sync with the
implementation. Adding a new outbound seam without registering it here is a
spec violation.

| Category | Trigger | Proxy applied | Implementation |
|---|---|---|---|
| Webview navigation (HTTP/HTTPS/CONNECT) | Site load, in-page request | Per-site (DEFAULT → global) | `ProxyManager.setProxySettings`, `lib/services/webview.dart:164` |
| Webview WebRTC | RTCPeerConnection / STUN | Per-site `webRtcPolicy` | `lib/services/location_spoof_service.dart` |
| Favicon: DDG, Google, FaviconFinder, SVG body | `getFaviconUrl(Stream)`, `getSvgContent`, `FaviconFinder.getAll` | Per-site (DEFAULT → global) | `lib/services/icon_service.dart`, `lib/third_party/favicon/favicon.dart` |
| Per-site downloads (HTTP/HTTPS) | `onDownloadStartRequest` | Per-site (DEFAULT → global) | `DownloadEngine`, `lib/services/webview.dart:_handleHttpDownload` |
| User-script remote fetches | `__ws_s_*` / `__ws_f_*` JS handlers | Per-site (DEFAULT → global) | `lib/services/user_script_service.dart` |
| OSM tile fetches | Location-picker "Load map" | Global only | `lib/screens/location_picker.dart` |
| ClearURLs rules download | "Update ClearURLs rules" | Global only | `ClearUrlService.downloadRules` |
| DNS blocklist download | "Update DNS blocklist" | Global only | `DnsBlockService.downloadList` |
| Content-blocker list download | "Update content-blocker list" | Global only | `ContentBlockerService.downloadList` |
| LocalCDN catalog download | LocalCDN cache populate | Global only | `LocalCdnService._downloadAndCache` |

#### Scenario: New outbound code path

**Given** a developer adds a new Dart-side `http.get(...)` somewhere in `lib/`
**Then** the code review process SHALL fail until either:
  - the call is rerouted through `outboundHttp.clientFor(...)` with the
    appropriate per-site or global proxy, **or**
  - the spec's coverage matrix gains a row justifying why the call is
    exempt (e.g. localhost-only, app-bundle resource fetch)

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  Per-site code path (favicon, download, user-script fetch)         │
│   ─ takes UserProxySettings from WebViewModel.proxySettings        │
│   ─ resolveEffectiveProxy(perSite)                                 │
│       └─ if DEFAULT, returns GlobalOutboundProxy.current           │
│           └─ if explicit, returns perSite                          │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
┌────────────────────────────────────────────────────────────────────┐
│  App-global code path (DNS blocklist, ClearURLs, OSM tiles, …)    │
│   ─ uses GlobalOutboundProxy.current directly                      │
└─────────────────────────┬──────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────────┐
│  outboundHttp.clientFor(UserProxySettings) → OutboundClient        │
│    DefaultOutboundHttpFactory:                                     │
│     ─ DEFAULT          → http.Client() (system / direct)           │
│     ─ HTTP/HTTPS       → IOClient(HttpClient..findProxy = …)       │
│     ─ SOCKS5           → IOClient(HttpClient..connectionFactory =  │
│                          socks5_proxy SocksTCPClient.connect(…))   │
│     ─ malformed addr   → OutboundClientBlocked  (fail-closed)      │
│    Tests inject a RecordingFactory that records every settings     │
│    object passed in, so call-site coverage is unit-testable.       │
└────────────────────────────────────────────────────────────────────┘
```

```
┌────────────────────────────────────────────────────────────────────┐
│  Webview proxy path (parallel, native)                             │
│    WebViewConfig.proxySettings ─→ ProxyManager.setProxySettings    │
│      ─ resolveEffectiveProxy() applied here too, so per-site       │
│        DEFAULT also inherits the global on the webview side        │
│      ─ ProxyController.setProxyOverride(...) on Android/iOS        │
└────────────────────────────────────────────────────────────────────┘
```

---

## Files

### Created
- `lib/services/outbound_http.dart` — `OutboundHttpFactory`, default impl,
  `resolveEffectiveProxy`, test override hook.
- `lib/settings/global_outbound_proxy.dart` — persistence + in-memory
  cache for the app-global outbound proxy.
- `test/outbound_http_test.dart` — unit tests for the factory, host:port
  parser, persistence, and `resolveEffectiveProxy`.
- `test/outbound_http_call_sites_test.dart` — proves per-site, global, and
  fail-closed behavior reaches each call site.
- `test/browser/proxy_baseline.test.js` — Tier 2 (real Chromium via
  Puppeteer) sanity checks on the engine the production WebView shares
  with Chrome: launches Chromium with `--proxy-server` + a Node-side
  HTTP proxy harness, asserts every navigation and subresource flows
  through the proxy log, that `page.authenticate` satisfies a 407
  challenge, that wrong credentials never fall through to the origin
  (the leak the recent Dart fix in PR #266 prevents at the higher
  level), and a paired premise check that without `--proxy-server`
  the same navigation hits the origin directly. Validates Chromium's
  proxy contract our Dart layer relies on.
- `test/browser/helpers/proxy_server.js` — Node HTTP/CONNECT proxy
  with optional Basic auth, request log; used by the proxy_baseline
  tier-2 test.

### Modified
- `lib/services/icon_service.dart`, `lib/third_party/favicon/favicon.dart`
  — favicon code paths thread per-site proxy through.
- `lib/services/clearurl_service.dart`,
  `lib/services/dns_block_service.dart`,
  `lib/services/content_blocker_service.dart`,
  `lib/services/localcdn_service.dart` — global download paths route
  through `outboundHttp` (SOCKS5 included via the `socks5_proxy`
  package's TCP tunnel; malformed configs still fail-closed).
- `lib/services/user_script_service.dart` — accepts per-site proxy and
  uses it for `__ws_s_*` / `__ws_f_*` handlers.
- `lib/services/download_engine.dart` — accepts per-site proxy; throws
  `DownloadException` when the proxy can't be honored.
- `lib/services/webview.dart` — `WebViewConfig.proxySettings` carries the
  per-site proxy; `ProxyManager.setProxySettings` resolves DEFAULT through
  global; download / user-script handlers receive the proxy.
- `lib/screens/location_picker.dart` — `TileLayer.tileProvider` is a
  `NetworkTileProvider` whose `httpClient` is built from `outboundHttp`.
- `lib/screens/app_settings.dart` — global "Outbound proxy" UI section.
- `lib/screens/inappbrowser.dart`, `lib/web_view_model.dart`,
  `lib/main.dart` — propagate `proxySettings` into nested
  `InAppWebViewScreen` so cross-domain links from a proxied site stay
  proxied (mirrors the existing per-site privacy fields).
- `lib/settings/app_prefs.dart` — registers `globalOutboundProxy` for
  backup/restore.
- `openspec/specs/proxy/spec.md`, `openspec/specs/per-site-location/spec.md`
  — cross-references this spec.

---

## Threat Model — Known Gaps

- **WebRTC default policy under a proxy**: per LEAK-005, sites with
  `webRtcPolicy = defaultPolicy` can still leak the device IP via STUN.
  The defense is to flip the per-site `webRtcPolicy` to `relayOnly` /
  `disabled`. The settings UI hints at this when a proxy is configured.
- **The app's own update / metrics**: WebSpace does not phone home, so
  there's no app-level analytics path to proxy. If telemetry is ever
  added, it MUST land in this matrix or be explicitly exempted with a
  rationale.
