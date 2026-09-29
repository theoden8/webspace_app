## ADDED Requirements

### Requirement: PROXY-029 - Saved proxies are defined once and named by sites

The app SHALL let the user define a proxy once, under a name, and pick it by
that name wherever a proxy is chosen: a site's Network screen and the app-wide
outbound proxy. A saved proxy SHALL carry one of HTTP, HTTPS or SOCKS5 and an
address, and MAY carry credentials. Tor SHALL NOT be a saved proxy's type: it
is one built-in route with per-site circuits (TOR-003), not a configuration to
share.

A site that picks a saved proxy SHALL store a reference to it
(`ProxyType.SAVED` and `savedProxyId`), not a copy. The reference SHALL be
resolved at use by `resolveEffectiveProxy`, so every outbound seam that
already resolves through it (the native binding, the Android override and
relay, the router, Dart-side HTTP) takes the saved proxy's current
configuration. Editing a saved proxy SHALL therefore change the route of every
site that names it, and SHALL dispose every loaded webview, as an app-wide
proxy change does, so none keeps routing through the configuration it was
bound with.

A reference that resolves to nothing, because the saved proxy was deleted or
the reference came from another device, SHALL fail closed: it resolves to
SAVED with no address, which every seam treats as unroutable. It SHALL NOT
fall through to the app-wide proxy or to a direct connection, both of which
are routes the user did not pick for that site. Deleting a saved proxy SHALL
first say how many sites use it, and whether the app-wide proxy does, and
that they will be blocked.

A reference SHALL keep the site's manual address and credentials, as TOR does
(PROXY-010), and picking another type SHALL keep the reference.

Sites that name one saved proxy have equal effective proxies, so Android
SHALL load them together under PROXY-008.

Sharing a site by QR SHALL carry the saved proxy's own type, address and
username in place of the reference, never its password; a reference that
resolves to nothing SHALL carry no proxy. A received payload that names a
saved proxy SHALL be refused, since the encoder never emits one.

The site settings Network row (NET-002) SHALL name a saved proxy by its name,
and a missing one as missing.

#### Scenario: One VPN for several sites

- **GIVEN** a saved proxy "Work VPN", SOCKS5 `10.8.0.1:1080`
- **AND** sites Mail and Chat both pick "Work VPN"
- **WHEN** either site loads
- **THEN** its traffic goes through `10.8.0.1:1080`
- **AND** on Android both stay loaded when switching between them

#### Scenario: An edit moves every site that names it

- **GIVEN** Mail and Chat name "Work VPN"
- **WHEN** the user changes its address to `10.9.0.1:1080` and saves
- **THEN** every loaded webview is disposed
- **AND** both sites route through `10.9.0.1:1080` when they next load

#### Scenario: A deleted saved proxy blocks, it does not go direct

- **GIVEN** Mail names "Work VPN" and the app-wide proxy is HTTP `1.2.3.4:8080`
- **WHEN** the user deletes "Work VPN"
- **THEN** the confirmation says one site uses it and will be blocked
- **AND** Mail's webview fails closed rather than loading
- **AND** no request from Mail goes through `1.2.3.4:8080` or direct

#### Scenario: The app-wide proxy can name a saved proxy

- **GIVEN** the app-wide proxy names "Work VPN"
- **AND** a site whose proxy type is DEFAULT
- **THEN** the site and the app's own downloads route through "Work VPN"

#### Scenario: A shared site carries the proxy, not the name

- **GIVEN** Mail names "Work VPN", which has a password
- **WHEN** the user shares Mail by QR
- **THEN** the payload's proxy is SOCKS5 `10.8.0.1:1080` with its username
- **AND** the payload carries no password and no saved-proxy id

---

### Requirement: PROXY-030 - A proxy in use says whether it answers

Wherever the app shows a proxy the user relies on, it SHALL show whether that
proxy answers: a coloured dot and one line, reading that the proxy works, that
it rejected the credentials, or that it could not be reached, and a progress
mark while it is checking. The check SHALL be one request sent through the
resolved proxy by the same `testProxyConnection` seam the connection test uses
(PROXY-019), so a route that fails closed there reads as not reached and never
probes over the device IP.

The indicator SHALL appear on every row of the saved proxies list, under a
site's proxy picker and under the app-wide picker while they name a saved
proxy, and in a Connection row of the URL-bar site info sheet. That row SHALL
name the route the site's traffic takes: direct, the app-wide proxy, a saved
proxy by name, the site's own proxy, or Tor; the indicator is absent for a
direct route. The row SHALL be absent where the platform binds no per-site
proxy (PROXY-006).

A check SHALL run only when an indicator is shown and its last answer is
older than two minutes, or when the user taps it again; never on a timer,
which would be traffic the user did not cause. Answers SHALL be kept per
proxy configuration, password included, so every surface showing one proxy
agrees and an edited proxy is checked afresh. A reference to a missing saved
proxy SHALL read as missing without a probe.

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
