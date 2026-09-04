## ADDED Requirements

### Requirement: PROXY-013 - Android per-site proxy router

Where container mode is available, Android SHALL route each site through
its own upstream proxy concurrently, rather than serialising mismatched
sites under PROXY-008.

`ProxyController` SHALL be pointed once at a loopback relay
(`http://127.0.0.1:<ephemeral>`, bypass `<local>`) and SHALL NOT be
repointed on site activation. The relay SHALL select each connection's
upstream from the `Proxy-Authorization` credential the WebView presents,
which the app answers per-WebView through `onReceivedHttpAuthRequest`.

Router mode SHALL be gated on `WebViewFeature.MULTI_PROFILE`. Chromium's
`HttpAuthCache` is owned by the `HttpNetworkSession` and its proxy entries
are not partitioned by `NetworkAnonymizationKey`, so without a per-profile
session every site would present the first site's credential. Where the
gate fails, PROXY-008 applies unchanged.

#### Scenario: Two same-domain sites with different proxies stay loaded

**Given** container mode is active on Android
**And** Site A (`accountA.example.com`) uses SOCKS5 `127.0.0.1:9050`
**And** Site B (`accountB.example.com`) uses HTTP `10.0.0.1:8080`
**When** the user activates Site B while Site A is loaded
**Then** Site A is NOT disposed
**And** each site's next request reaches its own upstream

#### Scenario: The process-wide rule names the relay, not a site's proxy

**Given** router mode has come up
**When** `ProxyController.setProxyOverride` is applied
**Then** the rule URL is `http://127.0.0.1:<relay port>`
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

### Requirement: PROXY-016 - A Tor site is blocked, never downgraded

The route table SHALL NOT encode a `ProxyType.TOR` site as any other
proxy type. A site whose effective proxy is TOR SHALL receive no route,
so the relay answers `502` and the site cannot reach the network.

Selecting TOR deliberately preserves the previous manual proxy address so
switching back restores it (PROXY-010), so a TOR setting normally carries
a stale address belonging to an unrelated proxy. The Tor runtime is
iOS-only and the router is Android-only, so on the router's platform
there is no endpoint that address could correctly resolve to. Encoding it
as a plain proxy would send a site the user put on Tor through an
unrelated host in clear, which is the failure TOR-008 forbids: a missing
resolver must never mean "connect anyway".

#### Scenario: A per-site Tor setting reaches the router

**Given** router mode is active
**And** a site's proxy type is TOR carrying a leftover manual address
**Then** the route table contains no entry for that site
**And** the relay answers `502` for its traffic

#### Scenario: A default site inherits an app-global Tor setting

**Given** router mode is active
**And** the app-global outbound proxy is TOR
**And** a site is left on DEFAULT
**Then** the route table contains no entry for that site

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

## MODIFIED Requirements

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
`proxyIsGlobal: false`

#### Scenario: Mixing platforms via settings backup

**Given** a settings backup is exported on iOS with two distinct
per-site proxies
**When** the backup is imported on Android
**Then** both per-site values are preserved in the data model
**And** whichever site is currently active drives the global
`ProxyController` state; switching between them cold-starts the other
under the proxy-mismatch unload rule above
