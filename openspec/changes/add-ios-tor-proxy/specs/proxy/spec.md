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
refcount holder keyed by `siteId`
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

### Requirement: PROXY-010 - Per-site Tor is the proxy type, not a second flag

A site opts into Tor by setting `proxySettings.type` to
`ProxyType.TOR`. There SHALL NOT be a separate per-site `useTor`
boolean.

An earlier draft of this change specified both. They encode the same
state, and two fields for one fact is a defect generator: every read
path has to agree on which wins, and the one that disagrees routes a
site the user believes is on Tor straight out the device IP. The
enum alone satisfies every scenario below, and it inherits the
nested-webview propagation, the settings-backup round-trip and the
proxy-password GC that `proxySettings` already has.

Selecting `TOR` SHALL leave the manual `address`, `username` and
`password` fields untouched on disk so switching back to `SOCKS5`
restores the previous configuration; while `TOR` is selected those
fields are inert. Entering the `TOR` state SHALL register the site
as a `TorService` refcount holder keyed by `siteId`; leaving it (or
deleting the site) SHALL release that holder.

#### Scenario: TOR overrides a stored manual SOCKS5 config

- **GIVEN** site A has `proxySettings.address = "192.0.2.1:1080"`
  and `type = SOCKS5`
- **WHEN** the user switches site A's proxy type to `TOR` and saves
- **THEN** the next webview navigation routes through
  `TorService.socksEndpoint`, NOT `192.0.2.1:1080`
- **AND** the stored `address` still reads `192.0.2.1:1080`

#### Scenario: Leaving TOR restores the manual config

- **GIVEN** site A has `type = TOR` and a stored
  `address = "192.0.2.1:1080"`
- **WHEN** the user switches the type back to `SOCKS5` and saves
- **THEN** the next navigation routes through `192.0.2.1:1080`
- **AND** `TorService`'s refcount for site A is released; if the
  count reaches 0 the idle-stop debounce begins

#### Scenario: TOR rides through to nested webviews

- **GIVEN** site A has `type = TOR`
- **WHEN** a cross-domain link opens a nested `InAppWebViewScreen`
- **THEN** the nested view resolves through the same
  `siteId`-tagged SOCKS5 settings as the top-level view
- **AND** both share one circuit, because `IsolateSOCKSAuth` keys
  circuits by the auth tuple and the tuple is identical

#### Scenario: TOR persists across app restart

- **GIVEN** site A has `type = TOR`
- **WHEN** the app is closed and reopened
- **THEN** `UserProxySettings.fromJson` decodes `type = TOR`
- **AND** the startup scan registers site A as a refcount holder
- **AND** site A's first navigation waits for bootstrap rather than
  loading direct (TOR-008)

#### Scenario: An unknown proxy type decodes to DEFAULT

- **GIVEN** a settings backup written by a build whose `ProxyType`
  enum has values this build does not
- **WHEN** `UserProxySettings.fromJson` reads it
- **THEN** the unknown index decodes to `ProxyType.DEFAULT`
- **AND** the settings load completes rather than throwing

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
**And** site A has `proxyType == DEFAULT`
**When** site A's favicon fetch runs
**Then** `resolveEffectiveProxy` returns the global TOR settings
**And** the SOCKS5 username is `__webspace_app_global__` (NOT
`siteId == a`)

The DEFAULT-inheritance case intentionally does NOT use the
per-site stream-isolation tag — sites that want per-site
stream isolation must select `TOR` explicitly. A site
inheriting Tor through the global is effectively asking "use the
app's default proxy" and gets the global isolation tag.

#### Scenario: Global TOR with an explicit per-site TOR uses the site tag

**Given** `globalOutboundProxy.type == TOR`
**And** site A has `proxyType == TOR`
**When** site A's favicon fetch runs
**Then** the SOCKS5 username is `siteA.siteId` (NOT
`__webspace_app_global__`)
**Because** an explicit per-site `TOR` wins over inheriting the
global one
