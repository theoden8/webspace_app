# Proxy Feature Specification

## Purpose

The proxy feature allows users to configure HTTP, HTTPS, and SOCKS5 proxies
for their web views on supported platforms. Three delivery paths coexist:

- **Android** — process-wide override via `inapp.ProxyController` (a
  WebView singleton). Per-site values live in the data model;
  activating a site disposes any other loaded site whose effective
  proxy differs before the global override flips, so per-site routing
  is honored at the cost of cold-starting mismatched sites on switch.
  This mutual exclusion is model-checked in
  [formal/proxy.tla](../../../formal/proxy.tla) as `Inv_ProxyCoherent`
  (every loaded site shares the active proxy); the `mismatch`
  demonstrator co-loads a mismatched site and TLC rejects it.
- **Linux** — global override via `inapp.ProxyController`. The fork's
  `flutter_inappwebview_linux` ProxyManager fans the override out
  across the default `WebKitNetworkSession` AND every cached
  container session (one per `siteId`), so a contained site honors
  the global proxy too. Per-site is still last-write-wins (no per-site
  proxy primitive on Linux), but contained sites no longer silently
  bypass it.
- **iOS 17+ / macOS 14+** — true concurrent per-site override via
  `WKWebsiteDataStore.proxyConfigurations`, set on the per-site data store
  created by the WebSpace fork's `preWKWebViewConfiguration` hook
  (resolved via `dependency_overrides` in
  [`pubspec.yaml`](../../../pubspec.yaml)).

The Android serialisation vs. iOS/macOS concurrency difference is
observable to the user; see
[PROXY-008](#requirement-proxy-008---android--ios-concurrency-asymmetry).

The integrity contract for which traffic actually flows through the
configured proxy — per-site vs. app-global, fail-closed-on-SOCKS5 from
Dart, WebRTC lockdown, DNS leak posture — lives in
[`openspec/specs/ip-leakage/spec.md`](../ip-leakage/spec.md). Any code
that adds a new outbound seam MUST be reflected there.

## Status

- **Status**: Completed
- **Platforms**: Android (per-site via serialised global override),
  iOS 17+ / macOS 14+ (concurrent per-site),
  Linux (global override via WebKitNetworkSession);
  Windows (system default — UI hidden).

---

## Requirements

### Requirement: PROXY-001 - Supported Proxy Types

The system SHALL support the following proxy types:

1. **DEFAULT** - Use system proxy settings (no override)
2. **HTTP** - HTTP proxy protocol
3. **HTTPS** - HTTPS proxy protocol (HTTP CONNECT over TLS to the proxy)
4. **SOCKS5** - SOCKS5 proxy protocol (ideal for Tor, SSH tunnels, etc.)

#### Scenario: Select HTTP proxy type

**Given** the user is on the settings screen for a site
**When** the user selects "HTTP" from the Proxy Type dropdown
**And** enters "proxy.example.com:8080" as the address
**And** saves settings
**Then** the site uses the HTTP proxy for all requests

---

### Requirement: PROXY-002 - Per-Webview Proxy Configuration

Each webview SHALL have its own proxy configuration in the data model
(`WebViewModel.proxySettings`). The configuration is persisted per site and
restored on app restart.

#### Scenario: Configure different proxies per site (iOS / macOS)

**Given** Site A and Site B exist on iOS 17+ / macOS 14+
**And** Site A and Site B share a base domain (so both can be loaded
concurrently under [container mode](../per-site-containers/spec.md))
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** Site A routes traffic through the SOCKS5 proxy
**And** Site B routes traffic through the HTTP proxy at the same time

#### Scenario: Configure different proxies per site (Android)

**Given** Site A and Site B exist on Android
**When** the user configures Site A with SOCKS5 proxy "localhost:9050"
**And** configures Site B with HTTP proxy "proxy.company.com:8080"
**Then** the data model stores both per-site values independently
**And** activating a site disposes any other loaded site whose effective
proxy differs before the global override flips (see PROXY-008 for the
underlying API constraint)

---

### Requirement: PROXY-003 - Runtime Proxy Switching

Users SHALL be able to change proxy settings without restarting the app.

#### Scenario: Change proxy at runtime (Android)

**Given** a site is currently using DEFAULT proxy on Android
**When** the user changes to SOCKS5 proxy "localhost:9050"
**And** saves settings
**Then** the proxy change takes effect on the next request via
`ProxyController.setProxyOverride`
**And** no app restart is required

#### Scenario: Change proxy at runtime (iOS / macOS)

**Given** a site is currently using DEFAULT proxy on iOS 17+ / macOS 14+
**When** the user changes to SOCKS5 proxy "localhost:9050"
**And** saves settings
**Then** the live `WKWebView` is discarded by
`WebViewModel.updateProxySettings` (which calls `disposeWebView`)
**And** the next render reconstructs the WebView with the new
`proxySettings` map applied to the per-site `WKWebsiteDataStore`
**And** subsequent requests route through the new proxy
**And** no app restart is required

The `WKWebsiteDataStore.proxyConfigurations` API is bound at
`WKWebView.init` and frozen on the live view, so swapping the proxy
without rebuilding the WebView is not possible — the dispose-and-rebuild
behavior is intentional.

---

### Requirement: PROXY-004 - Proxy Settings Persistence

Proxy settings SHALL persist across app restarts.

#### Scenario: Restore proxy settings on restart

**Given** a site is configured with SOCKS5 proxy "localhost:9050"
**When** the app is closed and reopened
**Then** the site still uses the SOCKS5 proxy configuration

---

### Requirement: PROXY-005 - Proxy Address Validation

The system SHALL validate proxy addresses before applying them.

#### Scenario: Validate proxy address format

**Given** the user is configuring a proxy
**When** the user enters an invalid address (e.g., "proxy.example.com" without port)
**Then** an error message is displayed: "Format: host:port"
**And** the settings are not saved

#### Scenario: Validate port range

**Given** the user is configuring a proxy
**When** the user enters "proxy.example.com:99999"
**Then** an error message is displayed: "Invalid port number"
**And** the settings are not saved

#### Scenario: Native side rejects malformed maps

**Given** the iOS / macOS path receives a `proxySettings` map missing
required keys (`type`, `host`, `port`) or with an out-of-range port
**Then** `inapp.ProxySettings.fromMap` returns an empty array
**And** the per-site data store's `proxyConfigurations` is cleared
**And** the site falls back to system default routing

---

### Requirement: PROXY-006 - Platform-Aware UI

Proxy configuration UI SHALL only be displayed on supported platforms.

#### Scenario: Hide proxy UI on unsupported platforms

**Given** the app is running on Windows
**When** the user opens site settings
**Then** the proxy configuration options are not displayed
**And** the site uses system default proxy automatically

#### Scenario: Show proxy UI on supported platforms

**Given** the app is running on Android, iOS 17+, macOS 14+, or Linux
**When** the user opens site settings
**Then** the proxy type dropdown and address field are displayed

`PlatformInfo.isProxySupported` is true on iOS 17+ / macOS 14+ only
(`appleOsMeetsFloor` over `Platform.operatingSystemVersion`); the fork's
`proxyConfigurations` bind is `#available(iOS 17.0, macOS 14.0, *)` and
no-ops below it. Below the floor the controls are hidden and a persisted
non-DEFAULT proxy (from a backup, a QR, or the app-wide proxy) makes the
webview fail closed (`proxyUnavailable`, blank load) instead of routing
through the system default (LEAK-003).

---

### Requirement: PROXY-007 - Localhost Bypass

The proxy configuration SHALL bypass localhost addresses to ensure local
resources work correctly. It SHALL achieve this without installing a
bypass list of its own.

#### Scenario: Access localhost without proxy (Android)

**Given** a SOCKS5 proxy is configured on Android
**When** the site accesses localhost:3000
**Then** the request connects directly, not through the proxy

Chromium bypasses loopback destinations of its own accord, so the app
passes an empty `bypassRules`. The earlier `<local>` entry was never what
made loopback reachable; it additionally exempted every dotless hostname,
which LEAK-011 now forbids. Defeating the loopback default takes an
explicit `<-loopback>`, which the browser test tier passes so a fake
origin on 127.0.0.1 goes through the proxy under test.

On iOS / macOS the `Network.framework` `ProxyConfiguration` API does not
expose a per-config bypass list; localhost routing is governed by
Apple's defaults (loopback addresses bypass automatically for HTTP
CONNECT and SOCKS5 proxies).

---

### Requirement: PROXY-008 - Android / iOS Concurrency Asymmetry

The system SHALL preserve per-site proxy semantics on every supported
platform. The runtime mechanism differs: iOS 17+ / macOS 14+ MUST run
distinct-proxy sites concurrently; Android MUST serialise them by
disposing any loaded site whose effective proxy differs before the
process-wide override flips, **unless PROXY-013 router mode is active**,
in which case Android MUST NOT dispose them and MUST route each site
concurrently through the relay.

#### Scenario: iOS / macOS — concurrent per-site proxy

**Given** container mode is active on iOS 17+ / macOS 14+
**And** Site A (`accountA.example.com`) and Site B (`accountB.example.com`)
are both loaded
**When** Site A is configured with proxy P1 and Site B with proxy P2
**Then** each site genuinely uses its own proxy at the same time
**Because** the proxy is attached to the per-site `WKWebsiteDataStore`,
which is partitioned per `siteId`

#### Scenario: Android — proxy-mismatch unload on activation

**Given** Site A is loaded on Android with HTTP proxy P1
**And** Site B is configured with SOCKS5 proxy P2
**And** router mode is NOT active
**When** the user activates Site B
**Then** every loaded site whose effective proxy differs from Site B
(including Site A) is disposed *before*
`ProxyController.setProxyOverride` applies P2 globally
**And** the data model preserves Site A's P1 setting

#### Scenario: Android — no unload under router mode

**Given** the same two sites on Android
**And** router mode is active
**When** the user activates Site B
**Then** Site A remains loaded
**And** `SiteUnloadEngine.indicesToUnloadForProxyMismatch` is called with
a `RoutedProxy` topology, under which only sites sharing the default
profile contend

#### Scenario: Mixing platforms via settings backup

**Given** a settings backup is exported on iOS with two distinct
per-site proxies
**When** the backup is imported on Android
**Then** both per-site values are preserved in the data model
**And** whichever site is currently active drives the global
`ProxyController` state; switching between them cold-starts the other
under the proxy-mismatch unload rule above

### Requirement: PROXY-009 - Per-site DEFAULT inherits global

When a site's [ProxyType] is `DEFAULT`, the effective proxy SHALL fall
through to the app-global outbound proxy configured in App Settings →
Outbound proxy. This applies in both directions: webview navigation
(`ProxyManager.setProxySettings` on Android, `proxySettings` on
iOS / macOS via `resolveEffectiveProxy`) and Dart-side outbound HTTP via
the `outboundHttp` factory.

See [LEAK-001](../ip-leakage/spec.md) for the full precedence ladder and
fail-closed semantics.

#### Scenario: Site with DEFAULT inherits global HTTP proxy

**Given** the app-global outbound proxy is `HTTP 10.0.0.1:8080`
**And** site "Acme" has Proxy Type `DEFAULT`
**When** the user opens "Acme"
**Then** webview navigation routes through `HTTP 10.0.0.1:8080`
**And** any per-site Dart-side fetch (favicon, download) routes through
`HTTP 10.0.0.1:8080` as well

---

### Requirement: PROXY-010 - A field the selected type hides keeps its stored value

A proxy configuration SHALL survive a round trip through a type that does not
render it. Switching a setting from a typed gateway to DEFAULT, to TOR, or to
a library entry (PROXY-030) and back SHALL restore the address and credentials
the user last entered, so trying another route for an afternoon does not cost
a configuration they then have to retype.

- **One place decides it.** `applyProxyForm` in
  [lib/services/proxy_form_engine.dart](../../../lib/services/proxy_form_engine.dart)
  is the only reader of this rule, shared by the per-site Network screen
  (NET-001) and the app-wide proxy form, so the two cannot disagree about it
  (PROXY-019). A field the selected type renders is authoritative and
  emptying it is how its value is removed; a field the type does not render
  SHALL NOT be written back, because its controller still holds whatever was
  last drawn.
- **What carries over.** The address under DEFAULT, TOR, a saved proxy and a
  saved gateway; the credentials under those types, and while saved
  credentials are picked. A typed gateway SHALL instead drop a
  saved-credentials reference, which fits saved gateways only and would fail
  closed on a typed one (PROXY-030).
- **A stored address is not a destination.** Because a setting keeps an
  address its type does not use, no consumer SHALL dial the stored address
  without resolving the type first: `resolveEffectiveProxy`, then
  `expandTorProxy` for TOR. A rule or route built for a Tor site out of that
  leftover address would reach an unrelated proxy in clear. Both the
  process-wide rule (`webview_proxy.dart`) and the router's routes
  (`proxy_router_engine.dart`) SHALL carry the endpoint the runtime serves
  with the site's own credential, and drop the route when the runtime is not
  up rather than send the site elsewhere (TOR-008). Gated by
  `test/js/process_wide_tor_isolation.test.js`.

#### Scenario: A trip through the library keeps the typed gateway

**Given** a site's proxy is SOCKS5 `127.0.0.1:1080` with credentials
**When** the user picks a saved proxy, saves, switches back to SOCKS5 and
saves again
**Then** the address and credentials are the ones first entered

#### Scenario: A typed gateway drops a saved credential it cannot use

**Given** a setting on a saved gateway with saved credentials picked
**When** the user switches the type to SOCKS5 and saves
**Then** the stored saved-credentials reference is null
**And** the address and credentials are what the fields held on screen

#### Scenario: A Tor site never dials the address it kept

**Given** a site that was SOCKS5 `10.0.0.1:8080` and is now TOR
**When** a proxy rule or a router route is built for it
**Then** it names the loopback endpoint the Tor runtime serves, carrying the
site's isolation tag as the SOCKS username
**And** `10.0.0.1:8080` appears in no rule and no route

---

### Requirement: PROXY-019 - Credentials are the fields, and the form can be tested

The proxy credential pair SHALL be stored as the form holds it: a visible
username or password field is written verbatim on save, and emptying a
field is the only way to remove that credential. No separate flag SHALL
gate whether credentials are saved.

The rule for which fields are authoritative lives in one place,
`applyProxyForm` in
[lib/services/proxy_form_engine.dart](../../../lib/services/proxy_form_engine.dart),
shared by the per-site and app-wide proxy forms. A field the selected type
does not render is not written back and keeps its stored value, which
PROXY-010 states in full.

The forms SHALL also offer a connection test that sends one request
through the configuration currently in the form — not the persisted copy
— and reports which of these happened: reachable, credentials rejected,
or not reached. The test SHALL route through the same
`resolveEffectiveProxy` / `outboundHttp` seam as any other Dart-side
call, so a configuration that fails closed there (Tor not bootstrapped,
malformed address) reports as not reached rather than silently probing
over the device IP.

The probe target is the site's own origin where there is one, and the
fixed `https://example.com` otherwise. A site whose host is a private or
loopback literal falls back to the fixed target: PROXY-007 exempts those
from the proxy, so testing against one would report success without a
byte having crossed it.

#### Scenario: A password with no username survives a save

**Given** a site's proxy is SOCKS5 with a password stored and no username
**When** the user opens site settings and saves
**Then** the credentials section is already expanded, showing the stored
password
**And** its subtitle says the pair is incomplete
**And** the saved settings still carry the password

#### Scenario: Clearing a field removes the credential

**Given** a site's proxy has both a username and a password
**When** the user clears both fields and saves
**Then** the stored username and password are both null

#### Scenario: Switching to TOR and back keeps the manual configuration

**Given** a site's proxy is SOCKS5 `127.0.0.1:1080` with credentials
**When** the user switches the type to TOR, saves, switches back to
SOCKS5 and saves again
**Then** the address and credentials are the original ones (PROXY-010)

#### Scenario: The test names a rejected credential

**Given** a proxy that answers with `407 Proxy Authentication Required`
**When** the user taps Test connection
**Then** the result reads as rejected credentials, not as an unreachable
proxy

#### Scenario: The test never falls back to a direct connection

**Given** a site set to TOR while the Tor runtime is not bootstrapped
**When** the user taps Test connection
**Then** `outboundHttp.clientFor` returns blocked
**And** the result reads as not reached, carrying the reason
**And** no request leaves over the device IP

---

### Requirement: PROXY-021 - Android authenticated proxy via local relay

On Android, a proxy whose effective settings carry credentials SHALL be
served through a native loopback relay rather than by embedding credentials
in the `inapp.ProxyController` proxy rule. Android WebView's
`ProxyController` has no proxy-authentication primitive and Chromium rejects
a proxy rule containing userinfo, which silently degrades to a direct
connection. The relay ([`ProxyRelay`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/proxy/ProxyRelay.kt))
SHALL accept HTTP proxy traffic on a loopback address, forward it to the
configured upstream, and inject the upstream credentials — HTTP
`Proxy-Authorization: Basic` for HTTP/HTTPS upstreams, the RFC 1929
username/password handshake for SOCKS5. WebView SHALL be pointed at
`http://<loopback address>:<port>` with no credentials in the rule; the
address is the one PROXY-024 binds, not a fixed `127.0.0.1`.

The relay SHALL bind a fresh random ephemeral port chosen by the OS on every
(re)start, SHALL bind to the loopback interface only, and SHALL NOT persist
the port. Unauthenticated Android proxies, and all non-Android platforms,
SHALL continue to use the direct `ProxyController` / native per-store path
and SHALL NOT start the relay.

#### Scenario: Authenticated HTTP proxy routes through the relay

- **GIVEN** the app runs on Android
- **AND** a site's effective proxy is `HTTP proxy.example.com:8080` with a username and password
- **WHEN** the proxy is applied
- **THEN** the native relay is started for that upstream
- **AND** `ProxyController` is set to `http://127.0.0.1:<ephemeral-port>` with no credentials
- **AND** the relay forwards `CONNECT` requests to the upstream with a `Proxy-Authorization: Basic` header derived from the credentials

#### Scenario: Authenticated SOCKS5 proxy performs RFC 1929 handshake

- **GIVEN** the app runs on Android
- **AND** a site's effective proxy is `SOCKS5 proxy.example.com:1080` with a username and password
- **WHEN** a request is made through the relay
- **THEN** the relay performs the SOCKS5 greeting offering username/password auth
- **AND** completes the RFC 1929 username/password sub-negotiation with the configured credentials before issuing the SOCKS CONNECT

#### Scenario: Unauthenticated proxy bypasses the relay

- **GIVEN** the app runs on Android
- **AND** a site's effective proxy has no credentials
- **WHEN** the proxy is applied
- **THEN** `ProxyController` is pointed directly at the upstream
- **AND** any relay started for a previous credentialed config is stopped

#### Scenario: Each start binds an independent loopback endpoint

- **WHEN** the relay is started
- **THEN** the bound port is an OS-assigned ephemeral port on the loopback interface
- **AND** neither the address nor the port is written to persistent storage

---

### Requirement: PROXY-023 - The relay serves only this app

Loopback keeps the listener off the network but not away from the device:
every other app holding `INTERNET` can reach `127.0.0.1:<port>`, and the relay
answers with the user's upstream credentials attached — an open proxy on their
account for as long as a credentialed site is loaded. Each accepted connection
SHALL therefore be checked against `/proc/net/tcp{,6}`: the peer's connection
appears as a row whose local port is the peer's and whose remote port is the
relay's, and field 7 names the UID owning it. The row SHALL be required to
carry this process's own UID; the port pair alone is the row *any* caller
creates, so a check that matched it and stopped would classify every caller as
OWN and reject nothing.

A readable table with no row for the peer, or one owned by another UID, is a
foreign process and the connection SHALL be closed before any upstream
connection is opened. An unreadable table is unverifiable, not hostile, and
SHALL be accepted, logged once per relay rather than per connection.

**Coverage.** `/proc/net` is readable only up to API 28: Android 10 denies it
outright rather than filtering it per-UID, so from API 29 every peer is
UNKNOWN and the check is inert. The app's `minSdkVersion` is 24, so this
covers API 24-28 and nothing above. No supported replacement exists —
`ConnectivityManager.getConnectionOwnerUid` answers only for the caller's own
`VpnService` tunnel, and TCP has no `SO_PEERCRED` — so on API 29+ no peer
lookup can answer. What stands there instead is the listener's address, not
this check: see PROXY-024.

Page script cannot reach the relay in the first place: `fetch` sends an
origin-form request line, which carries no host to forward and is answered with
`400`. This requirement is about other apps.

#### Scenario: A connection from another process is refused

- **GIVEN** the relay is running with a credentialed upstream on a readable table
- **WHEN** a connection arrives whose peer row carries another app's UID
- **THEN** the connection is closed without a response
- **AND** no upstream connection is opened, so no credentials are sent

#### Scenario: A matching port pair is not on its own sufficient

- **GIVEN** a readable table whose row for the peer is owned by another UID
- **WHEN** the peer is classified
- **THEN** it is FOREIGN, even though its local and remote ports match the
  relay's connection exactly

#### Scenario: The WebView's own connection is served

- **GIVEN** the relay is running
- **WHEN** the WebView in this process connects to it
- **THEN** the peer is found in this process's socket table and served normally

#### Scenario: An unreadable socket table does not break proxying

- **GIVEN** a device whose policy denies reading `/proc/net/tcp`
- **WHEN** a connection arrives
- **THEN** it is served, and the unverifiable check is logged once

---

### Requirement: PROXY-024 - The relay's loopback address is unguessable

On API 29+ no peer lookup can answer (PROXY-023), so the only thing between a
local app with `INTERNET` and the user's upstream credentials is the cost of
finding the listener. An ephemeral port alone is about 15 bits and a local
process scans that range in seconds.

The relay SHALL therefore bind a **random address within 127/8** drawn from a
cryptographic source, not `127.0.0.1`, and hand that address to
`ProxyController` alongside the port. The whole of 127/8 routes to the loopback
interface, and a connection to the same port on a different 127/8 address is
refused rather than aliased, so the address is roughly 24 further bits an
attacker must guess and not a decoration on the port.

The address SHALL be verified reachable from this process before it is used:
the relay connects to its own listener and falls back to `127.0.0.1` if that
fails. A device that will not route the random address loses the extra bits,
never proxying — and losing proxying is the IP leak PROXY-022 exists to
prevent.

#### Scenario: The listener is not on 127.0.0.1

- **WHEN** the relay starts on a device that routes 127/8 normally
- **THEN** its bound address is within 127/8 and is not `127.0.0.1`
- **AND** the proxy rule handed to `ProxyController` names that address

#### Scenario: The address is a barrier, not an alias

- **GIVEN** the relay is bound to a random 127/8 address
- **WHEN** a connection is made to `127.0.0.1` on the same port
- **THEN** it is refused

#### Scenario: An unroutable random address falls back rather than failing

- **GIVEN** a device on which the random 127/8 address binds but does not accept
  a connection from this process
- **WHEN** the relay starts
- **THEN** it rebinds on `127.0.0.1` and proxying continues

---

### Requirement: PROXY-022 - Auth proxy relay fails closed

The Android authenticated-proxy relay SHALL never open a direct connection
to an origin on behalf of a client; it SHALL only connect to the configured
upstream. When the upstream is unreachable or rejects authentication, the
relay SHALL return an error status (HTTP `502`) to the client and close the
connection. When the relay cannot bind its listener at all,
`ProxyManager.setProxySettings` SHALL throw and SHALL NOT clear the existing
proxy override — clearing it would let traffic flow directly and leak the
user's IP.

#### Scenario: Unreachable upstream does not leak direct

- **GIVEN** the relay is configured with an upstream that is unreachable
- **WHEN** a client opens a `CONNECT` request through the relay
- **THEN** the relay responds with `502`
- **AND** the relay does not connect the client directly to the requested origin

#### Scenario: Bind failure does not fall back to direct

- **GIVEN** applying a credentialed Android proxy
- **WHEN** the relay cannot bind a loopback port
- **THEN** `setProxySettings` throws
- **AND** the existing proxy override is left intact rather than cleared

---

### Requirement: PROXY-012 - Relay verifies the upstream's TLS identity

When the upstream proxy's type is HTTPS, the relay SHALL complete a TLS
handshake that verifies the server's certificate *identity* against the
configured upstream hostname — not only its chain against the system trust
store — before writing anything to the socket. A socket straight off
`SSLSocketFactory` performs no hostname check, and the first bytes the relay
writes are the user's `Proxy-Authorization: Basic` credentials followed by the
`CONNECT host:port` target, so an unverified handshake hands both to whoever
answered at that address.

When the handshake fails the relay SHALL close the socket and fail the
connection under PROXY-022 (`502` to the client). It SHALL NOT retry without
verification, downgrade to a plaintext hop, or fall back to a direct
connection.

#### Scenario: Certificate issued for another host is rejected

- **GIVEN** the upstream is `HTTPS proxy.example.com:8443` with credentials
- **AND** the host answering at that address presents a chain-valid certificate whose CN/SAN names `evil.example`
- **WHEN** a client opens a `CONNECT` request through the relay
- **THEN** the TLS handshake fails and the socket is closed
- **AND** the relay responds `502` to the client
- **AND** no `Proxy-Authorization` header and no `CONNECT` target is ever written to that socket

#### Scenario: Matching certificate proceeds to credential injection

- **GIVEN** the upstream is `HTTPS proxy.example.com:8443` with credentials
- **AND** the upstream presents a chain-valid certificate naming `proxy.example.com`
- **WHEN** a client opens a `CONNECT` request through the relay
- **THEN** the handshake completes
- **AND** the relay writes the `CONNECT` line and the `Proxy-Authorization: Basic` header over the encrypted socket

### Requirement: PROXY-013 - Per-site proxy router

Where container mode is available, the app SHALL route each site through
its own upstream proxy concurrently, rather than serialising mismatched
sites under PROXY-008. Android's delivery is below. Apple does not run the
router at all: it binds each store's own upstream (PROXY-026).

`ProxyController` SHALL be pointed once at a loopback relay
(`http://<127/8 host>:<ephemeral>`, no bypass entries -- LEAK-011) and
SHALL NOT be repointed on site activation. The host is the address the
relay actually bound, which is a random one in 127/8 rather than
`127.0.0.1`; the challenge answer is pinned to it as well as to the realm,
so a page serving its own `401` has to name an address it cannot read. The relay SHALL select each connection's
upstream from the `Proxy-Authorization` credential the WebView presents,
which the app answers per-WebView through `onReceivedHttpAuthRequest`.

Router mode SHALL be gated on `WebViewFeature.MULTI_PROFILE`. Chromium's
`HttpAuthCache` is owned by the `HttpNetworkSession` and its proxy entries
are not partitioned by `NetworkAnonymizationKey`, so without a per-profile
session every site would present the first site's credential. Where the
gate fails, PROXY-008 applies unchanged. The gate is per device; whether a
given site actually receives a profile is PROXY-018.

Router mode SHALL additionally be gated on its experimental switch
(DEVTOOLS-011): developer mode and the **Proxy router** switch, so the
shipped default on every device is PROXY-008. The switch defaults on, so
developer mode alone keeps running the router for a user who had it. The
premise the feature rests on is read off Chromium's source and proven at
runtime by the PROXY-015 probe, but so far only on WebView builds that pass
it: no device that fails the probe has exercised the fallback, and the one
defect that made the relay never bind at all was invisible to every test
tier. Both gates are read once, at activation, so flipping developer mode or
the switch applies at next launch rather than tearing a bound relay out from
under loaded sites. The gate is temporary and SHALL be lifted once the
fallback has been exercised on hardware that fails the probe.

#### Scenario: The default install does not engage router mode

**Given** an Android device whose WebView reports `MULTI_PROFILE`
**And** developer mode is off
**When** the app starts
**Then** router mode does not activate
**And** no relay is bound
**And** mismatched-proxy sites serialise under PROXY-008

#### Scenario: The switch off keeps PROXY-008 with developer mode on

**Given** an Android device whose WebView reports `MULTI_PROFILE`
**And** developer mode is on and the Proxy router switch is off
**When** the app starts
**Then** router mode does not activate
**And** mismatched-proxy sites serialise under PROXY-008

#### Scenario: Two same-domain sites with different proxies stay loaded

**Given** container mode is active on Android
**And** developer mode and the Proxy router switch are on
**And** Site A (`accountA.example.com`) uses SOCKS5 `127.0.0.1:9050`
**And** Site B (`accountB.example.com`) uses HTTP `10.0.0.1:8080`
**When** the user activates Site B while Site A is loaded
**Then** Site A is NOT disposed
**And** each site's next request reaches its own upstream

#### Scenario: The process-wide rule names the relay, not a site's proxy

**Given** router mode has come up
**When** `ProxyController.setProxyOverride` is applied
**Then** the rule URL is `http://<the address the relay bound>:<relay port>`
**And** it carries no site's proxy host, port, or credentials
**And** it is not reapplied when a site is activated

#### Scenario: A site left on the system default still reaches its origin

**Given** router mode is active
**And** Site C has proxy type `DEFAULT` and no app-global proxy is set
**When** Site C loads
**Then** its traffic arrives at the relay like every other site's
**And** the relay opens a direct connection to the origin for it

#### Scenario: A deleted site's credential stops routing

**Given** router mode is active and Site A has a route
**When** Site A is deleted
**Then** the route table is reinstalled without Site A's credential
**And** a connection bearing that credential is answered `502`

#### Scenario: Falling back when the router cannot come up

**Given** the relay fails to bind, or rejects the route table, or the
process-wide override fails to apply
**Then** router mode is NOT reported active
**And** the proxy override is NOT cleared
**And** the app falls back to the PROXY-008 serialisation

#### Scenario: Background-poll sites no longer contend

**Given** router mode is active
**And** two notification sites have different proxies
**Then** both may be enabled for background polling at once
**And** each poll reaches its own upstream with no reconfiguration

---

### Requirement: PROXY-018 - A site with no container profile is not its own identity

Router mode SHALL attribute traffic per *container profile*, not per site.
A site the app does not bind to a container profile -- an incognito site,
and an archive-tier site, which is always incognito -- SHALL present a
single shared credential rather than one of its own, and the app SHALL
keep evicting mismatched-proxy siblings within that group exactly as
PROXY-008 requires.

PROXY-013 gates on `MULTI_PROFILE` because Chromium's `HttpAuthCache`
lives in the `HttpNetworkSession` and its proxy entries are not
partitioned by `NetworkAnonymizationKey`. That gate answers whether the
*device* can give a site its own session; it does not answer whether
*this* site got one. A site that does not runs in the default profile,
sharing one session and one cached proxy credential with every other such
site -- the precise condition PROXY-013 names as unsafe.

Which sites those are is not this requirement's to decide: it is whatever
`siteOwnsContainerProfile` says, the same predicate the bind itself uses.
On Android today the answer is "all of them" -- incognito and
archive-tier sites bind a named profile there because Android has no
ephemeral one and an unbound site would leave its storage in the default
store (ARCH-006/ARCH-007), so the shared group is empty and this
requirement is inert. It was not inert before that rule changed, and one
predicate driving the bind, the routing identity, the eviction and the
probe is what makes routing follow the rule instead of restating it.

A per-site credential in that group is not a boundary. Chromium attaches
a cached proxy credential preemptively, so the first such site to
authenticate routes every later one, including after it has unloaded,
and nothing surfaces: the relay answers 200 and the page loads. One
shared identity whose upstream follows the active site of the group
removes the ambiguity, because a stale cached credential is then the
same credential and its route is current.

The shared identity SHALL carry no route when no site of the group is
active or loaded, so the relay answers `502` rather than sending the
next such site out through the previous one's upstream. Its route SHALL
be installed before the activating site can issue a request.

The PROXY-015 probe SHALL NOT attempt to attribute the shared identity:
it has no container to drive, and what the probe certifies is the
per-container boundary.

#### Scenario: Two sites the app did not bind to a profile

**Given** router mode is active on Android
**And** Site A is incognito with proxy P1
**And** Site B is incognito with proxy P2
**When** the user activates Site B while Site A is loaded
**Then** Site A is disposed before Site B's first request
**And** the shared identity's route names P2

#### Scenario: An incognito site does not evict a container-bound sibling

**Given** router mode is active on Android
**And** Site A is a normal site with proxy P1, loaded
**And** Site B is incognito with proxy P2
**When** the user activates Site B
**Then** Site A stays loaded
**Because** Site A has its own network session and its own cached
credential

#### Scenario: An unloaded shared-profile site has no route

**Given** router mode is active
**And** no incognito or archive-tier site is active or loaded
**Then** the route table has no entry for the shared identity

---

### Requirement: PROXY-014 - Relay stays unencrypted on loopback

The WebView-facing side of the relay SHALL be a plain HTTP proxy.

An HTTPS proxy rule causes Chromium to fail proxy authentication with
`net::ERR_PROXY_AUTH_UNSUPPORTED` without ever invoking
`onReceivedHttpAuthRequest`, which is the only per-WebView channel that
can carry a site's identity. TLS to a loopback listener in the same
process protects nothing, so the cost of omitting it is zero and the cost
of adding it is the whole feature.

#### Scenario: The relay is addressed over http

**Given** router mode is active
**Then** the proxy rule scheme is `http`
**And** the relay performs no TLS handshake with the WebView

### Requirement: PROXY-017 - Both proxy mechanisms agree on egress

For any per-site proxy configuration, router mode and the native
per-WebView binding SHALL send that site's traffic to the same
`(scheme, host, port)`, and SHALL agree on whether the site egresses
through a proxy at all.

Android routes by credential through the loopback relay because
`ProxyController` is process-wide; every other platform binds a proxy per
WebView. Two decision paths answering one question is how PROXY-016 got
in: the router encoded a Tor site's stale address as plain `http` while
the native path blocked it. The address parse SHALL therefore be a single
shared rule rather than a copy on each side.

#### Scenario: The same site configuration is resolved by both paths

**Given** any per-site proxy setting, including one inheriting the
  app-global proxy
**Then** the upstream router mode installs matches the upstream the
  native per-WebView binding would use
**And** where one refuses to egress, so does the other

#### Scenario: An IPv6 proxy literal

**Given** a site whose proxy address is a bracketed IPv6 literal
**Then** both mechanisms route it to that host and port
**And** neither drops the site for being unparseable

---

### Requirement: PROXY-016 - A Tor site is blocked, never downgraded

The route table SHALL NOT encode a `ProxyType.TOR` site as any other
proxy type, and SHALL NOT encode the address such a site carries. A TOR
route SHALL be the loopback SOCKS5 endpoint the Tor runtime is actually
serving, carrying that site's isolation tag as the SOCKS username -- the
same expansion the native per-WebView path applies, so PROXY-017 holds.
Where the runtime is not up the expansion yields nothing and the site
SHALL receive no route, so the relay answers `502` and the site cannot
reach the network.

Selecting TOR deliberately preserves the previous manual proxy address so
switching back restores it (PROXY-010), so a TOR setting normally carries
a stale address belonging to an unrelated proxy. Encoding it as a plain
proxy would send a site the user put on Tor through an unrelated host in
clear, which is the failure TOR-008 forbids: a missing resolver must never
mean "connect anyway".

This requirement used to say a TOR site receives no route at all, on the
grounds that the Tor runtime was Apple-only while the router was
Android-only, which is where the router runs. On Apple a Tor site's store
binds tor's SOCKS5 port directly with the site's own credential (PROXY-026),
so the route table is not in its path.

#### Scenario: A per-site Tor setting reaches the router

**Given** router mode is active
**And** the Tor runtime is up on a loopback SOCKS5 port
**And** a site's proxy type is TOR carrying a leftover manual address
**Then** the route table sends that site to the loopback SOCKS5 port
**And** the leftover manual address is not the upstream of any route

#### Scenario: The Tor runtime is not up

**Given** router mode is active
**And** a site's proxy type is TOR
**And** the Tor runtime is not serving a SOCKS5 endpoint
**Then** the route table contains no entry for that site
**And** the relay answers `502` for its traffic

#### Scenario: A default site inherits an app-global Tor setting

**Given** router mode is active
**And** the app-global outbound proxy is TOR
**And** the Tor runtime is not up
**And** a site is left on DEFAULT
**Then** the route table contains no entry for that site

---

### Requirement: PROXY-025 - A proxy credential reaches the platform's auth API

Where a per-site proxy carries credentials, the app SHALL deliver them in
every form the target platform reads, not only the one the URL carries.

`ProxyRule` exposes `url`, `username` and `password`. Linux's WPE binding
reads `url` alone, so credentials SHALL remain embedded as
`scheme://user:pass@host:port` userinfo. Apple's binding builds its
`ProxyConfiguration` endpoint from `URL.host` and `URL.port`, which
discards userinfo, and takes the credential from `username`/`password` to
hand to `ProxyConfiguration.applyCredential`; those fields SHALL therefore
be set whenever credentials exist.

A credentialed proxy delivered by URL alone authenticates with nothing on
Apple. The proxy answers `407`, the page fails, and the settings screen
still reports the proxy as configured -- the same "configured and not in
force" shape as BUG-014, arrived at from the app's side rather than the
platform's.

The app SHALL NOT refuse a credentialed proxy on Apple on the grounds that
the platform cannot authenticate. It can: BUG-014 attempt 80 measured two
container stores reaching two different upstreams through one relay
endpoint, told apart only by the credential each presented. WebKit bug
264309, which reported the header never being sent, is RESOLVED/MOVED and
was filed against a build two years older.

#### Scenario: A credentialed proxy is bound to a site

**Given** a site's proxy carries a username and password
**When** the per-WebView proxy settings are built
**Then** the rule's `username` and `password` fields carry them
**And** the rule's URL still carries them as userinfo

#### Scenario: An uncredentialed proxy

**Given** a site's proxy carries no credentials
**When** the per-WebView proxy settings are built
**Then** the rule's `username` and `password` fields are absent

---

### Requirement: PROXY-026 - Apple binds each store's real upstream, not a relay

Apple SHALL NOT run router mode. Each site's container data store SHALL
carry `proxyConfigurations` naming that site's **own upstream**, with its
credential in `ProxyRule.username`/`password` (PROXY-025).

The relay exists because Android has exactly one process-wide
`ProxyController` rule and Chromium caches a proxy credential per
`HttpNetworkSession` without partitioning it, so per-site proxies there need
something in front of them to fan out. Apple has neither problem:
`WKWebsiteDataStore` carries one proxy configuration per store, and BUG-014
BUG-014's remeasurement measured that delivering distinct upstreams AND distinct
credentials per store, on SOCKS5 (RFC 1929) and HTTP CONNECT (Basic) alike,
at any frame and on later navigations. A relay on Apple is therefore a local
hop that buys nothing while adding the credential-forwarding step PROXY-025
was a defect in. For Tor it is also strictly worse: `IsolateSOCKSAuth` keys a
circuit on the SOCKS credential tuple, and binding the site's own tuple to
the store hands tor the real per-site identity rather than depending on the
relay to re-present it upstream.

The implementation SHALL remain reachable behind
`ProxyRouterService.appleRelayEnabled`, which SHALL default false, so the two
platforms' router behaviour stays comparable in tests without a device. The
paragraphs below describe that path and apply only when it is enabled.

Every store SHALL be pointed at the relay, including a site whose own
effective proxy is DEFAULT. A store left unproxied would miss the
attribution probe and stand router mode down for every site; the relay
dials DEFAULT routes straight out.

The credential SHALL be presented preemptively via `applyCredential`
rather than in answer to a `407`. Android answers the challenge through
`onReceivedHttpAuthRequest`; WebKit exposes no equivalent for a proxy
challenge, and the relay's `407` is what an unattributable tunnel receives
rather than a step in the normal path.

A WebView the app cannot name a site for SHALL NOT be routed. It has no
row in the route table, and the shared-profile identity belongs to a group
it is not part of, so routing it there would put it on another site's
circuit; it keeps its own rule instead.

The relay on this platform SHALL be the in-process `LocalProxyRelay`
rather than the Android relay plugin, and SHALL speak HTTP CONNECT even
where the upstream is SOCKS5.

#### Scenario: Two sites with different proxies stay loaded

**Given** two sites on macOS have different upstream proxies
**When** both are loaded at once
**Then** each store's proxy configuration names that site's own upstream
**And** each presents its own credential
**And** neither site is unloaded for a proxy mismatch

#### Scenario: A site left on the system default

**Given** router mode is active on macOS
**And** a site's effective proxy is DEFAULT
**Then** that site's store is still pointed at the relay
**And** the relay dials its origin directly

#### Scenario: A webview with no site identity

**Given** router mode is active on macOS
**And** a webview is built without a site id
**Then** its store is not pointed at the relay
**And** it carries its own proxy rule instead

#### Scenario: The attribution probe travels the relay

**Given** router mode is activating on macOS
**When** the PROXY-015 probe drives a site's container
**Then** the probe's webview carries that site's relay credential
**And** the relay records the probe nonce against that site

---

### Requirement: PROXY-015 - Router mode verifies attribution on the device

Before router mode is treated as active, the app SHALL prove on the
running device that each container presents its own proxy credential.

Each site's container SHALL be driven to fetch a unique probe host under
`.webspace-probe.invalid`. The relay SHALL answer probe hosts itself and
SHALL NOT open any upstream for them, recording only which credential
carried which nonce. Router mode SHALL be activated only if every site's
nonce comes back attributed to that same site; a mismatched pair, a
missing pair, or a probe that fails to run SHALL each prevent activation
and fall back to PROXY-008.

This exists because the failure it detects is otherwise invisible.
Chromium caches a proxy credential per `HttpNetworkSession` and does not
partition proxy entries by `NetworkAnonymizationKey`, so on a device
where container profiles shared a session, every site would present
whichever credential was cached first. Pages would load, the relay would
return `200`, and one site would be exiting through another site's proxy
with nothing raised anywhere.

#### Scenario: A device that attributes correctly activates

**Given** router mode is starting with sites A and B
**When** each container fetches its own probe host
**And** the relay records A's nonce against A and B's nonce against B
**Then** router mode activates

#### Scenario: A device that mixes credentials is refused

**Given** router mode is starting with sites A and B
**When** both probes come back attributed to site A
**Then** router mode is NOT activated
**And** the relay is stopped
**And** the app falls back to the PROXY-008 serialisation
**And** the failure is logged naming the sites that could not be proven

#### Scenario: An unproven site is treated as a failed one

**Given** site B's probe never reaches the relay
**Then** router mode is NOT activated

#### Scenario: A probe cannot egress

**Given** a probe request for `<nonce>.webspace-probe.invalid`
**Then** the relay answers it locally
**And** no upstream connection is opened for it
**And** the hostname cannot resolve, being under the RFC 2606 reserved
`.invalid` TLD

---

### Requirement: PROXY-027 - Where a proxy is enforced is named, not re-derived

The app SHALL decide once per process whether a per-site proxy is carried
by the site's own network store or by a single process-wide rule, and every
path that binds a store, flips a process-wide override, or tears one down
SHALL read that decision rather than test the platform again.

Linux is the one documented exception, and it is a per-SITE condition
rather than a second process-level answer: WPE scopes a proxy to a
`WebKitNetworkSession`, only a container owns one, and a site without a
container has no session to pin (PROXY-018). No value decided once per
process can express that, so the call site that binds a store tests it
alongside the named binding. Nothing else may.

The decision SHALL be a pure function of the platform, evaluated through a
seam that takes the platform as arguments, so the cases are assertable on a
host that is not the one they describe. It SHALL be latched on first read:
a WebView built under one binding must not be driven by the other for the
rest of the run.

Router mode (PROXY-013) SHALL NOT be a third value. It changes what the
rule *names* -- the loopback relay rather than the site's upstream -- and
not where the rule lives, so it rides whichever binding is in force.
Modelling it as a binding would conflate two axes and make the binding
depend on runtime state.

The Apple decision SHALL NOT be gated on developer mode or any other
opt-in. An earlier form of it was, on the belief that only one
`WKWebsiteDataStore`'s `proxyConfigurations` is honoured per process;
BUG-014 attempts 80 and 90 measured several stores reaching several
distinct upstreams at once, so the gate guarded nothing and would cost
every Apple user their per-site proxy.

#### Scenario: Apple

**Given** the host is iOS or macOS
**Then** the binding is per store
**And** it is per store whatever else is configured

#### Scenario: Every other platform

**Given** the host is neither iOS nor macOS
**Then** the binding is process-wide

#### Scenario: Linux with a container

**Given** the host is Linux
**And** the site owns a container
**Then** the named binding is still process-wide
**And** the store is nonetheless bound per site, on the container's own
network session

#### Scenario: One decision, not many tests

**Given** a path that binds a store, flips a process-wide override, or
tears one down
**Then** it reads the named binding
**And** it does not test the platform itself

---

### Requirement: PROXY-028 - A proxy change is in force for everything after it

On iOS and macOS, once a site's effective proxy changes, no request the site
makes afterwards SHALL travel a connection opened on its previous route,
including requests to a host it had already reached.

A container's `WKWebsiteDataStore` keeps one network session for as long as
the store lives, and WebKit applies a SOCKS proxy change to that live
session in place: new connections take the new proxy, and connections
already pooled keep the old route and carry the site's next requests to the
same host (BUG-014 instance 8). The fork SHALL therefore make WebKit
rebuild a store's sessions whenever the store is given a proxy other than
the one it last had, which closes the connections opened on the old route.
A proxy the store already has is set as is: rebuilding then would cancel
the loads of the WebViews already on it. Cookies and storage are not
touched.

#### Scenario: A site moved from direct to Tor leaves through Tor

**Given** a site loaded a page directly
**When** the user moves it to Tor and it loads the same host again
**Then** the far side sees a Tor exit, not the device's address

#### Scenario: The same host after a proxy change uses the new proxy

**Given** a site loaded host H through proxy A over a kept-alive connection
**When** its proxy becomes B and it requests H again
**Then** the request reaches H through B
**And** proxy A carries nothing for the site after the change

### Requirement: PROXY-029 - A site moved off its proxy stops using it

On every platform that binds a proxy per container (iOS 17+, macOS 14+, and
Linux for a site that owns a container), once a site's effective proxy
resolves to none, its next WebView SHALL NOT issue a request through the
proxy its container was given before.

The fork (`privacy-v12`) keeps one proxy entry per container for the life of
the process. A WebView built with `InAppWebViewSettings.proxySettings` writes
it, and `ProxyController.setProxyOverride(containerId:)` writes the same
entry; a WebView built naming no proxy leaves it in force, and only
`ProxyController.clearProxyOverride(containerId:)` or deleting the container
takes it off. The app therefore records every container it builds a WebView
on with a proxy (`ProxyManager.noteStoreProxy`, gated by
`test/js/container_proxy_ledger_funnel.test.js`), and a site build whose
binding names no proxy for such a container defers its first load, clears
the container through `ProxyController` from `setController`, and loads
after the clear returns.

The proxy is still set at WebView construction rather than through
`ProxyController`: construction binds it before the store's first request
with no await in between, and an incognito store has no container id to
address. `ProxyController` is used only for the clear, which construction
cannot express.

A failed clear SHALL leave the page blank rather than load it through the
proxy the site gave up, and the next build SHALL ask again. A site whose
proxy is unavailable (PROXY-016, LEAK-003) SHALL NOT have its container
cleared: that page stays blank, and a stale proxy is still a proxy.

#### Scenario: Proxy removed

**Given** a site on iOS 17+ loaded through SOCKS5 proxy A
**When** the user sets the site's proxy to DEFAULT with no app-wide proxy
**Then** the rebuilt WebView issues no request until its container's proxy
is cleared
**And** its first request goes direct, not through A

#### Scenario: Container never given a proxy

**Given** a site that has used DEFAULT since the app started
**When** its WebView is built
**Then** nothing is cleared and the first load is not deferred

#### Scenario: Clear fails

**Given** the clear for a site's container fails
**Then** the page stays blank
**And** the next build of that site clears again before loading

---

### Requirement: PROXY-030 - A proxy library of saved proxies, gateways and credentials

The app SHALL keep a proxy library of three kinds of named entry:

- a **gateway**: a type (HTTP, HTTPS or SOCKS5) and an address;
- **credentials**: a username and password, and the gateways they work on,
  at least one;
- a **saved proxy**: a gateway choice (typed, or a saved gateway) and a
  credentials choice (typed, or saved credentials that list that gateway).

The library SHALL be offered with developer mode on or off. It shipped first
behind developer mode and an Experimental **Saved proxies** switch
(DEVTOOLS-011); it graduated, and the switch and its pref
(`experimentalProxyLibrary`, written by v0.3.3 and no longer read) went with
it.

With both halves typed, a saved proxy is simply a proxy, and the user never
has to create a gateway or credentials entry for it. Those entries exist for
what is shared: one account that works on several gateways, several accounts
on one gateway. Tor SHALL NOT be a gateway: it is one built-in route with
per-site circuits (TOR-003), not an endpoint to share.

Wherever a proxy is chosen (a site's Network screen and the app-wide outbound
proxy), the app SHALL offer the saved proxies and the saved gateways by name
beside the plain types. A setting on a saved gateway SHALL offer the saved
credentials that list it, and typed credentials; a setting on a typed gateway
SHALL offer typed credentials only. Credentials SHALL NOT be offered for a
gateway they do not list, and moving a setting to such a gateway SHALL drop
the saved credentials rather than keep a pairing that cannot sign in.

A setting SHALL store references (`ProxyType.SAVED` + `savedProxyId`,
`ProxyType.GATEWAY` + `gatewayId`, `credentialsId`), not copies. They SHALL be
resolved at use by `resolveEffectiveProxy`, so every outbound seam that
already resolves through it (the native binding, the Android override and
relay, the router, Dart-side HTTP) takes the entries' current values. Editing
an entry SHALL therefore change every route that uses it, directly or through
a saved proxy, and SHALL dispose every loaded webview, as an app-wide proxy
change does.

A reference that does not resolve SHALL fail closed: a missing saved proxy,
gateway or credentials, or credentials paired with a gateway they do not
list. It resolves to SAVED with no address, which every seam treats as
unroutable, and SHALL NOT fall through to the app-wide proxy or to a direct
connection. Deleting an entry SHALL first say how many sites use it, through
a saved proxy included, and whether the app-wide proxy does, and that they
will be blocked. Deleting a gateway SHALL remove it from every credentials
entry's list. The Network row (NET-002), the site info sheet and the
connection indicator SHALL name what failed.

A setting SHALL keep its typed address and credentials across a switch to
the library and back (PROXY-010).

Settings that resolve to the same route have equal effective proxies, so
Android SHALL load them together under PROXY-008; one gateway with two sets
of credentials is two routes, kept apart unless router mode (PROXY-013) is
on.

Sharing a site by QR SHALL carry the resolved type, address and username in
place of the references, never a password; a reference that does not resolve
SHALL carry no proxy. A received payload that names the library SHALL be
refused, since the encoder never emits one.

#### Scenario: The library needs no developer mode

- **GIVEN** developer mode is off and the library holds saved proxy "Work VPN"
- **WHEN** the user opens a site's Network screen
- **THEN** its proxy picker offers "Work VPN"
- **AND** App Settings shows the Saved proxies row
- **AND** the Experimental group has no Saved proxies switch

#### Scenario: One VPN, typed once

- **GIVEN** the user adds a saved proxy "Home", SOCKS5 `192.0.2.1:1080`, with
  both halves typed
- **AND** sites Mail and Chat pick "Home"
- **THEN** both route through `192.0.2.1:1080`
- **AND** no gateway or credentials entry was created

#### Scenario: One account on several gateways

- **GIVEN** gateways "VPN US" and "VPN DE", and credentials "Alice" that list
  both
- **AND** site Mail uses "VPN US" with "Alice", and site Chat uses "VPN DE"
  with "Alice"
- **WHEN** the user changes Alice's password
- **THEN** both sites sign in with the new password

#### Scenario: Several accounts on one gateway

- **GIVEN** gateway "VPN DE" and credentials "Alice" and "Mail session" that
  both list it
- **AND** site Mail uses "VPN DE" with "Mail session"
- **THEN** Mail signs in to `de.gw:1080` as the Mail session user
- **AND** on Android without router mode, activating Mail unloads a loaded
  site that uses "VPN DE" with "Alice"

#### Scenario: Credentials are offered only where they fit

- **GIVEN** "Mail session" lists "VPN DE" only
- **WHEN** a site picks "VPN US"
- **THEN** "Mail session" is not offered
- **AND** a site that had "VPN DE" with "Mail session" and moves to "VPN US"
  has its credentials dropped

#### Scenario: A deleted entry blocks, it does not go direct

- **GIVEN** Mail uses saved proxy "Work VPN" and the app-wide proxy is HTTP
  `1.2.3.4:8080`
- **WHEN** the user deletes the gateway "Work VPN" is built on
- **THEN** the confirmation says one site uses it and will be blocked
- **AND** Mail's webview fails closed rather than loading
- **AND** no request from Mail goes through `1.2.3.4:8080` or direct

#### Scenario: A pairing that does not fit blocks

- **GIVEN** a site on "VPN US" with credentials that do not list it (a
  hand-edited backup, or a list edited since)
- **THEN** the site fails closed
- **AND** its Network row reads that the credentials don't fit the gateway

#### Scenario: The app-wide proxy can use the library

- **GIVEN** the app-wide proxy names "Work VPN"
- **AND** a site whose proxy type is DEFAULT
- **THEN** the site and the app's own downloads route through "Work VPN"

#### Scenario: A shared site carries the route, not the references

- **GIVEN** Mail uses "VPN DE" with "Mail session"
- **WHEN** the user shares Mail by QR
- **THEN** the payload's proxy is SOCKS5 `de.gw:1080` with the Mail session
  username
- **AND** the payload carries no password and no library id

---

### Requirement: PROXY-031 - A proxy in use says whether it answers

Wherever the app shows a proxy the user relies on, it SHALL show whether that
proxy answers: a coloured dot and one line, reading that the proxy works, that
it rejected the credentials, or that it could not be reached, and a progress
mark while it is checking. The check SHALL be one request sent through the
resolved proxy by the same `testProxyConnection` seam the connection test uses
(PROXY-019), so a route that fails closed there reads as not reached and never
probes over the device IP.

The indicator SHALL appear on every saved proxy in the library, under a
site's proxy picker and under the app-wide picker while they use the library,
and in a Connection row of the URL-bar site info sheet. That row SHALL name
the route the site's traffic takes: direct, the app-wide proxy, a saved proxy
or gateway by name, the site's own proxy, or Tor; the indicator is absent for
a direct route. The row SHALL be absent where the platform binds no per-site
proxy (PROXY-006).

A check SHALL run only when an indicator is shown and its last answer is
older than two minutes, or when the user taps it again; never on a timer,
which would be traffic the user did not cause. Answers SHALL be kept per
proxy configuration, password included, so every surface showing one proxy
agrees and an edited proxy is checked afresh. A route that does not resolve
SHALL name what failed without a probe. An indicator whose proxy changes
under it, as while an address is typed, SHALL wait a second before probing,
so no intermediate `host:port` is sent a request.

#### Scenario: The list shows which proxies are up

- **GIVEN** three saved proxies, one reachable, one refusing its password,
  one not listening
- **WHEN** the user opens Saved proxies
- **THEN** the rows read "The proxy works", "The proxy rejected these
  credentials" and "Could not reach the proxy"

#### Scenario: The site info sheet names the route

- **GIVEN** a site that names "Work VPN"
- **WHEN** the user opens the site info sheet from the URL bar
- **THEN** its Connection row reads "Work VPN", with the proxy's type and
  address beneath, and whether it answers

#### Scenario: No background probing

- **GIVEN** the saved proxies list was checked a minute ago
- **WHEN** the user opens it again
- **THEN** no request is sent
- **AND** tapping a row's check button sends one

## Data Model

### ProxyType Enum

```dart
enum ProxyType { DEFAULT, HTTP, HTTPS, SOCKS5 }
```

### UserProxySettings

```dart
class UserProxySettings {
  ProxyType type;
  String? address;   // Format: "host:port"
  String? username;  // Optional credentials
  String? password;
}
```

### iOS / macOS wire format

When passed through `inapp.InAppWebViewSettings.proxySettings`, the
settings are translated by `_proxySettingsToWebspaceProxy` in
[lib/services/webview.dart](../../../lib/services/webview.dart) into:

```dart
{
  'type':     'http' | 'https' | 'socks5',
  'host':     'proxy.example.com',
  'port':     8080,
  'username': 'optional',
  'password': 'optional',
}
```

`ProxyType.DEFAULT`, missing addresses, or malformed entries return
`null`. Since fork `privacy-v12` a WebView built with `null` leaves its
container's proxy as it was; clearing it is PROXY-029's job.

---

## Architecture

```
lib/settings/proxy.dart
├── ProxyType enum
└── UserProxySettings class

lib/services/webview.dart
├── PlatformInfo.isProxySupported          (Android: feature-flag; iOS/macOS/Linux: always true)
├── ProxyManager.setProxySettings           (Android/Linux: ProxyController; iOS/macOS: no-op)
├── inapp.InAppWebViewSettings.proxySettings
└── _proxySettingsToWebspaceProxy

lib/web_view_model.dart
├── proxySettings field                                (per-site; persisted)
├── _applyProxySettings()                              (Android only)
└── updateProxySettings()                              (Android: ProxyController; iOS/macOS: dispose+rebuild)

lib/screens/settings.dart
└── Proxy configuration UI (per-site; no cross-site sync)

flutter_inappwebview fork (github.com/theoden8/flutter_inappwebview)
├── flutter_inappwebview_ios
├── flutter_inappwebview_macos
│   └── proxySettings field + preWKWebViewConfiguration block
│       + the fork's ProxySettings handling helper (NWEndpoint / ProxyConfiguration builder)
└── flutter_inappwebview_linux
    └── ProxyManager method channel
        ├── webkit_network_session_set_proxy_settings(WEBKIT_NETWORK_PROXY_MODE_CUSTOM)
        └── fan-out across default + every cached container session
            (sessions_to_apply_proxy_to() / container_session_cache())
```

---

## Platform Support

| Platform | Proxy Support | UI Visibility | Behavior |
|----------|--------------|---------------|----------|
| Android  | Full (per-site, serialised) | Shown (when `PROXY_OVERRIDE` feature present) | `inapp.ProxyController` singleton; data model is genuinely per-site, but mismatched-proxy sites cannot stay loaded concurrently — activation cold-starts the conflicting ones (PROXY-008) |
| iOS      | Full (per-site, iOS 17+) | Shown on iOS 17+ | WebSpace fork attaches `proxyConfigurations` to per-site `WKWebsiteDataStore`; removing a site's proxy clears it through `ProxyController(containerId:)` (PROXY-029); below iOS 17 the controls are hidden and a persisted non-DEFAULT proxy fails closed (blank load) |
| macOS    | Full (per-site, macOS 14+) | Shown on macOS 14+ | Same pattern as iOS; below macOS 14 the controls are hidden and a persisted non-DEFAULT proxy fails closed |
| Linux    | Full (global override, fan-out) | Shown unconditionally | WebSpace fork's `flutter_inappwebview_linux` ProxyManager applies `webkit_network_session_set_proxy_settings` to the default session AND every cached container session, so contained sites honor the global proxy too; per-site is still last-write-wins (no per-site proxy primitive on Linux) |
| Windows  | Limited      | Conditional   | Shown only if `PROXY_OVERRIDE` supported |

---

## Files

### Created
- `lib/settings/proxy.dart` - Proxy types and settings model
- `lib/services/proxy_form_engine.dart` - the one form-to-settings rule (PROXY-019)
- `lib/services/proxy_test_service.dart` - the connection test (PROXY-019)
- `lib/widgets/proxy_auth_section.dart` - the credentials fold
- `lib/widgets/proxy_test_tile.dart` - the test control and its result
- `test/proxy_test.dart` - Unit tests
- `test/proxy_integration_test.dart` - Integration tests
- WebSpace fork of `flutter_inappwebview` (github.com/theoden8/flutter_inappwebview) -
  per-site `proxySettings` field on `flutter_inappwebview_ios` /
  `flutter_inappwebview_macos`, plus `the fork's ProxySettings handling` helper

### Modified
- `lib/services/webview.dart` - `inapp.InAppWebViewSettings.proxySettings`, ProxyManager iOS no-op, PlatformInfo iOS gate
- `lib/web_view_model.dart` - per-site proxy passed into `WebViewConfig`; iOS rebuild on update
- `lib/screens/settings.dart` - per-site proxy UI (no cross-site sync)
- `lib/services/site_unload_engine.dart` - `indicesToUnloadForProxyMismatch` enforces single-proxy-at-a-time on Android

---

## Manual Test Procedure

### iOS / macOS concurrent per-site proxy

1. Add two sites that share a base domain (e.g. two `github.com` accounts).
2. Configure Site A with HTTP proxy `127.0.0.1:8080` and Site B with
   SOCKS5 proxy `127.0.0.1:9050` (run two local proxies of different
   shapes — `mitmproxy` and `dante`, for example).
3. Open Site A: requests must show up in `mitmproxy` only.
4. Switch to Site B without unloading Site A (container mode allows both
   to be loaded simultaneously): requests must show up in `dante` only.
5. Both proxies should remain active for their respective sites.

### Android serialised per-site proxy

1. Same setup as above on Android.
2. Save Site A's config: per-site value is stored in Site A's
   `proxySettings`. Save Site B's config: per-site value is stored in
   Site B's `proxySettings`. Site A's stored value is unchanged.
3. Open Site A: requests show up in `mitmproxy`.
4. Switch to Site B: Site A is disposed by `indicesToUnloadForProxyMismatch`
   *before* the global override flips to Site B's proxy; requests show
   up in `dante` only. Site A's `proxySettings` still contains its
   original value.
5. Switch back to Site A: Site B is disposed; the global flips to Site
   A's proxy; Site A cold-starts and routes through `mitmproxy`.

### Older OS fallback

1. Restore a backup carrying a non-DEFAULT per-site proxy onto iOS 16 or
   macOS 13.
2. Site settings show no proxy controls
   (`PlatformInfo.isProxySupported` is false below the floor).
3. The site renders blank rather than loading over the device IP
   (`proxyUnavailable`); the same holds for every site while the app-wide
   proxy is non-DEFAULT.
