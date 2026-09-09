## ADDED Requirements

### Requirement: LEAK-009 - The loopback relay authenticates its callers

The relay's listening socket SHALL admit only callers presenting a
credential in its current route table. A connection with no credential
SHALL be answered `407`; one bearing an unknown credential SHALL be
answered `502` and SHALL NOT be re-challenged. No connection SHALL be
routed to any upstream, or to a direct connection, without a match.

Android places every installed app on one loopback interface and offers no
way for a normal app to identify the peer of a local TCP connection
(`ConnectivityManager.getConnectionOwnerUid` is restricted to VPN apps
over their own tunnel, and `/proc/net/tcp` is unreadable from API 29). The
credential is therefore the only admission control this socket can have,
and the ephemeral port is not one: 64K loopback ports are scanned in about
a second.

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

## ADDED Requirements

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

#### Scenario: A site on a dotless hostname

**Given** a proxy is configured, in router mode or not
**When** the WebView navigates to a host with no dot in it
**Then** the request goes through the proxy
**And** it is not sent direct

#### Scenario: The installed override carries no exemption

**Given** the app applies a proxy override
**Then** its bypass list is empty
