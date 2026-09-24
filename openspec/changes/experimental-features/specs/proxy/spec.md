## MODIFIED Requirements

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
