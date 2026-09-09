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

### Requirement: PROXY-013 - The relay serves only this app

Loopback keeps the listener off the network but not away from the device:
every other app holding `INTERNET` can reach `127.0.0.1:<port>`, and the relay
answers with the user's upstream credentials attached — an open proxy on their
account for as long as a credentialed site is loaded. Each accepted connection
SHALL therefore be checked against `/proc/net/tcp{,6}`, which on API 29+ lists
only the calling UID's sockets: a connection this process opened appears there
as a row whose local port is the peer's and whose remote port is the relay's,
and another app's does not.

A readable table that does not list the peer is a foreign process and the
connection SHALL be closed before any upstream connection is opened. An
unreadable table is unverifiable, not hostile — some kernels and SELinux
policies deny the read — and SHALL be accepted, logged once per relay rather
than per connection. Failing closed there would strand proxying entirely for a
threat that needs a malicious app already installed.

Page script cannot reach the relay in the first place: `fetch` sends an
origin-form request line, which carries no host to forward and is answered with
`400`. This requirement is about other apps.

#### Scenario: A connection from another process is refused

- **GIVEN** the relay is running with a credentialed upstream
- **WHEN** a connection arrives whose peer socket is not one of this process's
- **THEN** the connection is closed without a response
- **AND** no upstream connection is opened, so no credentials are sent

#### Scenario: The WebView's own connection is served

- **GIVEN** the relay is running
- **WHEN** the WebView in this process connects to it
- **THEN** the peer is found in this process's socket table and served normally

#### Scenario: An unreadable socket table does not break proxying

- **GIVEN** a device whose policy denies reading `/proc/net/tcp`
- **WHEN** a connection arrives
- **THEN** it is served, and the unverifiable check is logged once

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
connection under PROXY-011 (`502` to the client). It SHALL NOT retry without
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
