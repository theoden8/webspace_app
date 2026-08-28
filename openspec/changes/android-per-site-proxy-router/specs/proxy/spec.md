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
