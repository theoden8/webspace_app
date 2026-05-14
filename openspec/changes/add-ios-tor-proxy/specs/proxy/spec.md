## MODIFIED Requirements

### Requirement: PROXY-001 - Supported Proxy Types

The system SHALL support the following proxy types:

1. **DEFAULT** - Use system proxy settings (no override)
2. **HTTP** - HTTP proxy protocol
3. **HTTPS** - HTTPS proxy protocol (HTTP CONNECT over TLS to the proxy)
4. **SOCKS5** - SOCKS5 proxy protocol (ideal for Tor, SSH tunnels, etc.)
5. **TOR** - Embedded Tor runtime; resolves at use-time to the
   `SOCKS5 127.0.0.1:<dynamicPort>` endpoint exposed by
   `TorService` with per-call stream-isolation auth (see
   [`openspec/specs/tor-proxy/spec.md`](../tor-proxy/spec.md)
   TOR-001 / TOR-003). Available only on platforms where
   `TorService.isAvailable == true` (iOS in the initial release).

#### Scenario: Select HTTP proxy type

**Given** the user is on the settings screen for a site
**When** the user selects "HTTP" from the Proxy Type dropdown
**And** enters "proxy.example.com:8080" as the address
**And** saves settings
**Then** the site uses the HTTP proxy for all requests

#### Scenario: Select TOR proxy type (iOS)

**Given** the user is on the settings screen for a site on iOS
**When** the user selects "TOR" from the Proxy Type dropdown
**Then** the manual `host:port` / credentials fields are hidden (the
underlying values, if previously set, are preserved but inert)
**And** saving settings registers the site as a `TorService`
refcount holder
**And** the next request from that site is materialized as
SOCKS5 to `TorService.socksEndpoint` with username equal to the
site's `siteId`

#### Scenario: TOR proxy type is hidden on unsupported platforms

**Given** the user is on the settings screen for a site on Android
**When** the user opens the Proxy Type dropdown
**Then** "TOR" is not listed
**And** the user falls back to manual SOCKS5 if they want to use
Orbot or a similar local SOCKS5 server

---

## ADDED Requirements

### Requirement: PROXY-010 - Per-site useTor field

`WebViewModel` SHALL carry a `useTor: bool` field, persisted via
`toJson`/`fromJson`, defaulting to `false`. When `useTor` is true on
a site, the effective per-site proxy SHALL resolve to the live
`TorService` SOCKS5 endpoint with username = `siteId`, irrespective
of the user's manual `address`/`username`/`password` values (the
manual values are preserved but inert so toggling `useTor` off
restores the prior configuration). Setting `useTor=true` SHALL
implicitly increment `TorService`'s refcount via
`TorService.maybeStart`; setting it back to `false` SHALL decrement
via `TorService.release`.

#### Scenario: useTor overrides manual SOCKS5 config

**Given** site A has `proxySettings.address = "192.0.2.1:1080"` (a
public SOCKS5 server) and `useTor = false`
**When** the user enables `useTor` on site A and saves
**Then** the next webview navigation routes through
`TorService.socksEndpoint`, NOT `192.0.2.1:1080`
**And** the stored `address` field on `proxySettings` still reads
`192.0.2.1:1080` for restoration when `useTor` is disabled

#### Scenario: Disabling useTor restores manual config

**Given** site A has `useTor = true` and a previously-stored manual
`address = "192.0.2.1:1080"`
**When** the user disables `useTor` on site A and saves
**Then** the next webview navigation routes through
`192.0.2.1:1080`
**And** `TorService`'s refcount is decremented; if it reaches 0 the
runtime begins its idle-stop debounce

#### Scenario: useTor rides through to nested webviews

**Given** site A has `useTor = true`
**When** a cross-domain link on site A opens a nested
`InAppWebViewScreen`
**Then** the nested view's `WebViewConfig.proxySettings` resolves
through `TorService.socksFor(siteId = a)` exactly like the top-level
view
**And** the nested view's traffic uses the same site-isolated Tor
circuit as the top-level view (same SOCKS auth → same circuit per
Tor's `IsolateSOCKSAuth` semantics)

#### Scenario: useTor persists across app restart

**Given** site A has `useTor = true`
**When** the app is closed and reopened
**Then** `WebViewModel.fromJson` decodes `useTor = true` on site A
**And** `main.dart`'s startup scan calls `TorService.maybeStart`
**And** site A's first navigation waits for Tor to bootstrap before
loading (per TOR-008 interstitial)

---

### Requirement: PROXY-011 - Global outbound proxy supports TOR

The app-global outbound proxy (`globalOutboundProxy`) SHALL accept
`ProxyType.TOR`. When selected, app-global Dart-side traffic (DNS
blocklist download, ClearURLs rules, content-blocker filter lists,
LocalCDN catalog, OSM tiles) SHALL route through
`TorService.socksFor("__webspace_app_global__")` rather than the
HTTP/HTTPS/SOCKS5 path. Per-site sites with `ProxyType.DEFAULT`
SHALL inherit this global setting, so a single switch in App
Settings can route every "DEFAULT" site through Tor without
flipping each site individually.

#### Scenario: Global TOR routes app-global download

**Given** `globalOutboundProxy.type == TOR`
**When** `DnsBlockService.downloadList` runs
**Then** `outboundHttp.clientFor(globalSettings)` opens a TCP socket
to `TorService.socksEndpoint`
**And** the SOCKS5 username is `__webspace_app_global__`

#### Scenario: Global TOR inherited by DEFAULT sites

**Given** `globalOutboundProxy.type == TOR`
**And** site A has `proxyType == DEFAULT` and `useTor == false`
**When** site A's favicon fetch runs
**Then** `resolveEffectiveProxy` returns the global TOR settings
**And** the SOCKS5 username is `__webspace_app_global__` (NOT
`siteId == a`)

The DEFAULT-inheritance case intentionally does NOT use the
per-site stream-isolation tag — sites that opted into per-site
stream isolation must set `useTor = true` explicitly. A site
inheriting Tor through the global is effectively asking "use the
app's default proxy" and gets the global isolation tag.

#### Scenario: Global TOR with per-site useTor uses per-site tag

**Given** `globalOutboundProxy.type == TOR`
**And** site A has `useTor == true`
**When** site A's favicon fetch runs
**Then** the SOCKS5 username is `siteA.siteId` (NOT
`__webspace_app_global__`)
**Because** explicit per-site `useTor` wins over inheriting global
TOR
