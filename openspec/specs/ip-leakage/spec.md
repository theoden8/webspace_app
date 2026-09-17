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

#### Scenario: Favicon bytes are rendered from the proxied client

**Given** site "Acme" has proxy `HTTP 10.0.0.1:8080`
**And** the winning favicon URL for "Acme" points at a host the page chose
**When** the drawer, tab strip or site list renders that favicon
**Then** the recording fake observes `clientFor(HTTP 10.0.0.1:8080)`
**And** the image widget issues no HTTP request of its own

#### Scenario: Blocked client renders the fallback icon

**Given** site "Acme" has a proxy the factory cannot honor
**When** its favicon is rendered
**Then** the placeholder gives way to the fallback icon
**And** no direct (unproxied) request is made for the icon

#### Scenario: Timezone dataset download passes global proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**When** the user taps "Download timezone data"
**Then** the recording fake observes `clientFor(HTTP 10.0.0.1:8080)`
**And** a `Blocked` result aborts the download and returns false

#### Scenario: User-script editor download passes the site proxy

**Given** the user saves a script whose URL source has not been fetched yet
**When** the editor downloads that URL
**Then** the recording fake observes the site's resolved proxy
**And** a `Blocked` result surfaces its reason instead of downloading

#### Scenario: OSM map tiles pass global proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**When** the user opens the location picker and taps "Load map"
**Then** the picker constructs a `NetworkTileProvider` whose `httpClient`
came from `outboundHttp.clientFor(HTTP 10.0.0.1:8080)`
**And** every subsequent tile request goes through that client

#### Scenario: Media-session artwork passes the site proxy

**Given** site "Acme" has proxy `HTTP 10.0.0.1:8080`
**And** its page reports playback with an `artwork` URL
**When** `MediaSessionService.report` fetches the artwork
**Then** the recording fake observes `clientFor(HTTP 10.0.0.1:8080)`
**And** a `Blocked` result drops the artwork and still raises the
notification, rather than fetching direct

#### Scenario: Page-title probe passes the resolved proxy

**Given** the app-global outbound proxy is `SOCKS5 127.0.0.1:9050`
**When** `getPageTitle` runs — from add-site, the title refresh in the site
editor, the shortcut create-site path, or `_executeCreateSite` handling an
inbound shared link
**Then** the recording fake observes `clientFor(SOCKS5 127.0.0.1:9050)` for a
site whose proxy is `DEFAULT`, and the site's own proxy otherwise
**And** a `Blocked` result skips the title fetch and returns null

**Because** the URL comes from a share intent or deep link on the
`_executeCreateSite` path, so a direct `http.get` handed an
attacker-authored host the device IP of a user who had configured Tor.

#### Scenario: Artwork cannot be used to probe the local network

**Given** a page reports playback with an `artwork` URL whose host is a
loopback, RFC1918, unique-local or link-local literal (including
`169.254.169.254`)
**When** `MediaSessionService.report` runs
**Then** no outbound client is requested and no request is made
**Because** the URL is page-supplied and the media-session shim runs in
every frame

---

### Requirement: LEAK-003 - SOCKS5 tunneling and fail-closed posture

Every Dart-side outbound seam SHALL route SOCKS5 traffic through the [`socks5_proxy`](https://pub.dev/packages/socks5_proxy) package's TCP tunnel — both the destination's TCP connection and its hostname resolution travel through the SOCKS5 server, so the local resolver never sees the user's destination — and SHALL fail-closed (skip the request entirely, never fall back to a direct connection) when the proxy is malformed or otherwise un-tunnelable, since falling back would leak the device IP to the very party the user picked the proxy to hide it from.

Webview navigation continues to use SOCKS5 via its native channel — the
patched iOS / macOS plugins' `WKWebsiteDataStore.proxyConfigurations` and
Android's `inapp.ProxyController` — independently of the Dart-side path.

The native binding SHALL be verified by its effect rather than by the
call that requests it: the plugin's settings parser discards a field it
cannot see, so a webview can report a proxy it never bound (BUG-014). A
site whose proxy refuses connections SHALL therefore never reach its
origin.

On iOS and macOS, **a load is proxied only if the webview issues it as it is
constructed, and only if that webview is constructed in the process's first
frame.** Both halves are required. A first-frame webview navigated by
`loadUrl` from inside `onWebViewCreated` is proxied; the same call on a
sibling first-frame webview once the tree has settled is not; a webview
constructed in any later frame is not, even by its `initialUrlRequest`.
Measured across BUG-014 attempts 19-32 with webviews built straight from the
plugin, carrying nothing but a container id and a proxy — no
`shouldOverrideUrlLoading`, no universal-link bypass, no per-site policy — so
the behaviour is the platform's and not this app's.

Three readings are excluded by measurement rather than by argument:

* Not **elapsed time**, and not a **race**. One first-frame webview navigated
  five times in succession went direct on every step, the first of them issued
  at 0 ms.
* Not **the load mechanism**. `loadUrl` is proxied inside `onWebViewCreated`
  and direct afterwards.
* Not a **process-wide proxy the newest store overwrites**. Two webviews
  carrying *different* proxies in one later frame both went direct, neither
  one's traffic arriving at the other's proxy.

The measurement is not "the proxy was bound and failed". In the same run, a
site whose proxy pointed at a closed port reached no origin at all, which is
what a bound proxy does when it cannot connect. And it is read from the
fixture proxy's own CONNECT log rather than from the origin's request log: the
fixture relays a proxied load to the origin too, so a path arriving there says
nothing about whether it was proxied.

The mechanism, read end to end from WebKit's source (BUG-014 attempt 36), is
that the proxy never reaches an `NSURLSessionConfiguration` at all.
`WebsiteDataStore::setProxyConfigData` nulls `m_proxyConfigData` before
calling `networkProcess()`, and `parameters()` is read inside that call, so
`AddWebsiteDataStore` always carries no proxy. The `NetworkSessionCocoa`
constructor then calls `initializeNSURLSessionsInSet` eagerly, and
`applyProxyConfigurationToSessionConfiguration` runs with `m_nwProxyConfigs`
empty and writes `proxyConfigurations = @[ ]` onto the session configuration.
The proxy arrives afterwards, as its own message, by which time the wrappers
have sessions -- so it lands as a patch on a live `nw_context`
(`nw_context_clear_proxies` then `nw_context_add_proxy`) rather than on the
session. A SOCKS5 configuration never makes
`nw_proxy_config_stack_requires_http_protocols` true, so it never takes
`recreateSessionWithUpdatedProxyConfigurations`, which is the one route that
would put the proxy on the session's own configuration durably.

That is consistent with every reading: a load issued while the patch is fresh
is proxied, and anything after it is not.

The rest of the path says a bound proxy should persist, in more than one place.
`WKWebsiteDataStore.setProxyConfigurations:` hands the agent data to
`WebsiteDataStore::setProxyConfigData`, which keeps it in `m_proxyConfigData`
for the life of the store; `WebsiteDataStore::parameters()` carries it into the
session's creation parameters; `NetworkSessionCocoa::setProxyConfigData` keeps
it in `m_nwProxyConfigs` and patches every live session wrapper's `nw_context`;
and `SessionWrapper::initialize` replays `m_nwProxyConfigs` onto the
`NSURLSessionConfiguration` of every wrapper created afterwards.
`WebsiteDataStore::dataStoreForIdentifier` returns the *same* store for a given
UUID, so a container has one session and one stored proxy, and
`NetworkProcess::addWebsiteDataStore` never replaces a session that exists.
Exactly one path takes a proxy off a live store: assigning an empty
`proxyConfigurations`, which reaches `clearProxyConfigData` and empties
`m_nwProxyConfigs`.

The fork had such a path. `ProxyManager.setProxyOverride` wrote the
process-wide rule over every cached container store and `clearProxyOverride`
wrote `[]` over them, so setting a global override swapped a site's own proxy
for the global one and clearing it dropped that site to the device IP. A store
a webview binds with its own `proxySettings` is now pinned and skipped by that
fan-out. It does not account for the measurement above, which is taken with
webviews that never reach `ProxyManager`, so the contradiction stands and the
observation governs.

The consequence is that `WKWebsiteDataStore.proxyConfigurations` cannot carry
this feature. Proxying a site's landing page and leaking every link its user
follows is worse than not offering the proxy, because the app reports the site
as proxied while it is not. So on iOS and macOS a site whose effective proxy is
non-DEFAULT SHALL fail closed — blank the load rather than fetch it over the
device IP — until a delivery mechanism exists that survives navigation.

This governs the Tor tier too: per-site Tor on iOS and macOS rides the same
path and inherits the same limit.

#### Scenario: A proxied site does not leak on its second navigation

**Given** site "Acme" carries `SOCKS5 127.0.0.1:<fixture>`
**And** its first load went through that proxy
**When** its page follows a link to a second origin
**Then** that load does not reach the second origin directly

#### Scenario: A proxied webview navigated in the same turn still uses its proxy

**Given** a webview carrying `SOCKS5 127.0.0.1:<fixture>` is created in the
process's first frame with no initial request
**When** it is navigated by `loadUrl` from that frame's own turn
**Then** the fixture proxy receives a CONNECT for that destination

#### Scenario: Two proxied sites in one launch each use their own proxy

**Given** sites "Acme" and "Beta" each carry `SOCKS5 127.0.0.1:<fixture>`
**And** both WebViews are created in the process's first frame
**When** each loads a page from a routable origin
**Then** the fixture proxy receives a CONNECT for each of them
**And** neither load reaches the origin directly

#### Scenario: A refused proxy does not become a direct load

**Given** site "Acme" has proxy `SOCKS5 127.0.0.1:<closed port>`
**And** the platform binds the proxy per WebView (iOS 17+ / macOS 14+)
**When** the site loads a page served from a routable (non-loopback) origin
**Then** the origin receives no request for it
**And** an unproxied control load from the same harness does reach that
origin, so a page that simply failed to load cannot pass for a bound proxy

#### Scenario: A site that gains a proxy stops going direct

**Given** site "Acme" has loaded once with no proxy, so its container's
data store is in service
**When** the user gives it a proxy and the site's webview is rebuilt
**Then** the load arrives at that proxy
**And** the user does not have to restart the app for it to take effect

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

#### Scenario: Add-site preview does not probe the local resolver

**Given** any non-DEFAULT proxy resolves for the app
**When** the user types a hostname into Add Site and the preview updates
**Then** no `InternetAddress.lookup` is issued for that hostname
**And** the preview card is shown without a reachability probe

#### Scenario: Add-site preview still probes with no proxy

**Given** no proxy is configured
**When** the user types a hostname that does not resolve
**Then** the reachability probe runs and the preview card stays hidden

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
| Favicon raster render | Drawer / tab strip / site list paints an icon | Per-site (DEFAULT → global) | `getIconBytes` in `lib/services/icon_service.dart`, `lib/screens/favicon_image_io.dart` |
| Per-site downloads (HTTP/HTTPS) | `onDownloadStartRequest` | Per-site (DEFAULT → global) | `DownloadEngine`, `lib/services/webview.dart:_handleHttpDownload` |
| User-script remote fetches | `__ws_s_*` / `__ws_f_*` JS handlers | Per-site (DEFAULT → global) | `lib/services/user_script_service.dart` |
| User-script URL-source download | Saving a script with a URL in the editor | Per-site (DEFAULT → global) | `fetchUserScriptSource`, `lib/screens/user_scripts.dart` |
| OSM tile fetches | Location-picker "Load map" | Global only | `lib/screens/location_picker.dart` |
| ClearURLs rules download | "Update ClearURLs rules" | Global only | `ClearUrlService.downloadRules` |
| DNS blocklist download | "Update DNS blocklist" | Global only | `DnsBlockService.downloadList` |
| Content-blocker list download | "Update content-blocker list" | Global only | `ContentBlockerService.downloadList` |
| LocalCDN catalog download | LocalCDN cache populate | Global only | `LocalCdnService._downloadAndCache` |
| Timezone polygon dataset download | "Download timezone data" | Global only | `TimezoneLocationService.download` |

#### Scenario: New outbound code path

**Given** a developer adds a new Dart-side `http.get(...)` somewhere in `lib/`
**Then** the code review process SHALL fail until either:
  - the call is rerouted through `outboundHttp.clientFor(...)` with the
    appropriate per-site or global proxy, **or**
  - the spec's coverage matrix gains a row justifying why the call is
    exempt (e.g. localhost-only, app-bundle resource fetch)

#### Scenario: The matrix is checked by machine, not only by review

**Given** the Linux integration tier running under the deny-by-default
egress guard ([INTEG-016](../integration-tests/spec.md))
**When** any scenario reaches a destination outside loopback that
[`scripts/egress_allowlist.txt`](../../../scripts/egress_allowlist.txt)
does not cover
**Then** the run records the host and, in `enforce` mode, fails
**And** the three outcomes above are the three ways to clear it — route it
through the seam, point it at a loopback fixture, or add an argued
allowlist entry alongside the matrix row

---

### Requirement: LEAK-008 - Proxy hops authenticate the far end

Any hop the app terminates to a *proxy* — as opposed to an origin — SHALL
authenticate that proxy's identity before writing anything that identifies the
user or their destination. The app terminates two such hops. On Android the
credentialed-proxy relay's TLS handshake to an HTTPS upstream MUST verify the
certificate identity against the configured upstream hostname (the normative
requirement is [PROXY-012](../proxy/spec.md)). The Dart-side outbound client
(`DefaultOutboundHttpFactory`, behind favicons, downloads, page-title probes,
user-script and list downloads) MUST open a TLS session to an `HTTPS`-type
proxy before it writes `CONNECT` or `Proxy-Authorization`, verified against
system trust or a fingerprint the user pinned in `TrustedHostsService`;
`findProxy` alone would have dart:io write both on a plain socket. Gated by
`test/outbound_https_proxy_hop_test.dart` against real sockets.

An unverified handshake there is a total compromise of the proxy's purpose,
not a partial one: the impostor collects the proxy credentials, every
`CONNECT host:port` the proxy existed to conceal, and every plaintext body.
Chain-only validation does not prevent it — any attacker holding a valid
certificate for a name they own passes it.

#### Scenario: Impostor upstream learns nothing

**Given** an on-path attacker answers for the configured HTTPS upstream with a
chain-valid certificate for a domain the attacker owns
**When** the webview issues any request through the relay
**Then** the relay's handshake fails before its first write
**And** the attacker observes no proxy credentials and no `CONNECT` target
**And** the client receives `502` — the relay does not fall back to a direct
connection

#### Scenario: A Dart-side fetch under an HTTPS-type proxy

**Given** a site whose proxy is `HTTPS` with Basic credentials
**When** the favicon fetch or a download opens its connection to the proxy
**Then** the first bytes on the wire are a TLS ClientHello
**And** `CONNECT host:port` and the credentials are written only inside that session
**And** the origin's own TLS handshake runs through the tunnel as before

---

### Requirement: LEAK-012 - Android webview auth-proxy fail-closed

On Android, applying a credentialed proxy to the WebView SHALL NOT degrade
to a direct connection on failure. Credentials SHALL NOT be embedded in the
`inapp.ProxyController` proxy rule (Chromium rejects userinfo and silently
goes direct); they SHALL instead be injected by the native loopback relay
(see PROXY-021 / PROXY-022), which only ever connects to the configured
upstream. Credentials SHALL travel to the relay only over the loopback
method channel and SHALL NOT appear in any `ProxyController` rule or on any
non-loopback socket from the app. If the relay cannot be established, the
webview proxy application SHALL fail closed (no override cleared, no direct
fallback) consistent with the SOCKS5 fail-closed posture in LEAK-003.

#### Scenario: Credentialed Android proxy never sets a userinfo rule

- **GIVEN** the app runs on Android with a credentialed effective proxy
- **WHEN** the proxy is applied
- **THEN** the `ProxyController` rule is `http://127.0.0.1:<port>` with no userinfo
- **AND** the username and password are present only in the relay's upstream connection

#### Scenario: Relay failure does not leak the IP

- **GIVEN** a credentialed Android proxy whose relay cannot start
- **WHEN** the proxy is applied
- **THEN** no direct-connection override is left active for that site's traffic
- **AND** the failure is logged at error level

### Requirement: LEAK-009 - The loopback relay authenticates its callers

The relay's listening socket SHALL admit only callers presenting a
credential in its current route table. A connection with no credential
SHALL be answered `407`; one bearing an unknown credential SHALL be
answered `502` and SHALL NOT be re-challenged. No connection SHALL be
routed to any upstream, or to a direct connection, without a match.

Android places every installed app on one loopback interface and offers no
way for a normal app to identify the peer of a local TCP connection
(`ConnectivityManager.getConnectionOwnerUid` is restricted to VPN apps
over their own tunnel, and `/proc/net/tcp` is denied outright from API 29,
so the peer check bites on API 24-28 and is inert above it). The
credential is therefore the admission control that holds on every version,
and the ephemeral port is not one: 64K loopback ports are scanned in about
a second. The random address the listener binds within 127/8 adds ~24 bits
to that search but is likewise not admission control: it raises the cost
of finding the socket, it does not decide who may use it.

Tokens SHALL be at least 128 bits from a cryptographic RNG, SHALL live in
memory for one app run only, SHALL never be persisted, and SHALL never be
written to a log or forwarded upstream.

#### Scenario: Another app on the device cannot borrow the user's proxy

**Given** the relay is running with a route for Site A
**When** any local process connects to the relay port without a credential
**Then** it receives `407`
**And** no upstream connection is opened

#### Scenario: A guessed credential does not get a retry loop

**Given** the relay is running
**When** a caller presents a credential that is not in the route table
**Then** it receives `502` with no `Proxy-Authenticate` header
**And** no upstream connection is opened

#### Scenario: The site token is not disclosed to the proxy operator

**Given** Site A routes through an authenticated upstream
**When** the relay opens that upstream
**Then** the upstream receives the user's own proxy credentials
**And** it does NOT receive the site's router token

---

### Requirement: LEAK-010 - Page JS cannot obtain or forge a router token

A site's own content SHALL NOT be able to present another site's router
credential, nor read its own.

`Proxy-Authorization` is a forbidden header name, so `fetch` and `XHR`
cannot set it; the token is held in Chromium's per-profile auth cache and
is exposed to no web API; and the relay strips the header before opening
the upstream, so an origin never observes it. The app SHALL additionally
refuse to answer any auth challenge that is not the relay's, matching on
both the loopback host and the current realm nonce — Android's callback
drops `is_proxy` and the port, so a site's own `401` is otherwise
indistinguishable.

#### Scenario: A page cannot put Proxy-Authorization on the wire

**Given** a page under the app's WebView
**When** it issues a `fetch` or `XHR` carrying a `Proxy-Authorization`
header
**Then** the header does not reach the server

#### Scenario: A site's own 401 is never answered with a token

**Given** router mode is active
**When** a site serves `401 WWW-Authenticate: Basic realm="<the nonce>"`
**Then** the app cancels the challenge
**And** no credential is sent

#### Scenario: An origin never sees the token

**Given** Site A loads an `http://` page through its proxy
**Then** the origin's request headers carry no `Proxy-Authorization`

### Requirement: LEAK-011 - No proxy bypass list exempts a site

The proxy override the app installs SHALL carry no bypass entry that can
exempt a site's traffic. In particular it SHALL NOT pass `<local>`.

Chromium reads `<local>` as "send simple, dotless hostnames direct", so a
site at `http://intranet/` leaves the device without touching the proxy at
all -- and under router mode, without touching the relay that decides
which upstream it is allowed. That is the defeat this spec's purpose
names: one outbound path that bypasses the proxy defeats the proxy.

`<local>` is not what makes the loopback relay reachable. Chromium
bypasses loopback of its own accord, which is why the browser tier has to
pass `<-loopback>` to defeat it and reach a fake origin on 127.0.0.1.

The exemption is decided on the URL host alone, before anything is
resolved: any host with no dot in it takes it. Two properties make that
reachable by an attacker rather than merely untidy.

**Any page can emit the request.** A single-label host is not something
only the user can type. `<img src="http://intranet/p?id=...">`, a `fetch`,
a subframe, or a `302` to `http://intranet/` all take the same exemption,
so a remote page chooses when the device opens an unproxied connection.
LEAK-002's artwork scenario already treats page-supplied hosts as hostile
on the Dart side; the webview path must not be softer.

**The network decides what the host means.** A single-label name has no
global meaning. It resolves through the platform resolver, whose servers
and search list come from the network the device is attached to (DHCP /
router advertisement), so whoever runs that network -- or can answer for
it on the path -- chooses the address `intranet` resolves to, a public
address they own included. Under SOCKS5 this inverts LEAK-006: the
webview would otherwise hand the name to the proxy to resolve remotely,
and `<local>` handed precisely the network-controlled names back to the
local resolver.

Together they compose: a remote page names a single-label host, the local
network resolves it to a collector, and the device connects direct. The
parties the user configured a proxy to hide from -- the local network and
the ISP -- are the ones that receive the connection and the device's real
address.

#### Scenario: A page-supplied subresource on a single-label host

**Given** a proxy is configured
**When** a loaded page requests `http://intranet/beacon` as a subresource
**Then** the request goes through the proxy like every other subresource
**And** no connection is made outside it

#### Scenario: A site on a dotless hostname

**Given** a proxy is configured, in router mode or not
**When** the WebView navigates to a host with no dot in it
**Then** the request goes through the proxy
**And** it is not sent direct

#### Scenario: The installed override carries no exemption

**Given** the app applies a proxy override
**Then** its bypass list is empty

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
