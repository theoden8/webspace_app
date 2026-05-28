## ADDED Requirements

### Requirement: PROXY-010 - Android authenticated proxy via local relay

On Android, a proxy whose effective settings carry credentials SHALL be
served through a native loopback relay rather than by embedding credentials
in the `inapp.ProxyController` proxy rule. Android WebView's
`ProxyController` has no proxy-authentication primitive and Chromium rejects
a proxy rule containing userinfo, which silently degrades to a direct
connection. The relay ([`ProxyRelay`](../../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/proxy/ProxyRelay.kt))
SHALL accept HTTP proxy traffic on `127.0.0.1`, forward it to the configured
upstream, and inject the upstream credentials — HTTP `Proxy-Authorization:
Basic` for HTTP/HTTPS upstreams, the RFC 1929 username/password handshake
for SOCKS5. WebView SHALL be pointed at `http://127.0.0.1:<port>` with no
credentials in the rule.

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

#### Scenario: Each start binds an independent loopback port

- **WHEN** the relay is started
- **THEN** the bound port is an OS-assigned ephemeral port on the loopback interface
- **AND** the port is not written to persistent storage

---

### Requirement: PROXY-011 - Auth proxy relay fails closed

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
