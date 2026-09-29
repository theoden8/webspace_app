## ADDED Requirements

### Requirement: PROXY-029 - A proxy library of saved proxies, gateways and credentials

The app SHALL keep a proxy library of three kinds of named entry:

- a **gateway**: a type (HTTP, HTTPS or SOCKS5) and an address;
- **credentials**: a username and password, and the gateways they work on,
  at least one;
- a **saved proxy**: a gateway choice (typed, or a saved gateway) and a
  credentials choice (typed, or saved credentials that list that gateway).

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

### Requirement: PROXY-030 - A proxy in use says whether it answers

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
