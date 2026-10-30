# Network interface

## ADDED Requirements

### Requirement: NETIF-001 - A site names the interface its traffic leaves by

A site's proxy settings SHALL carry an `InterfaceChoice`
(`lib/settings/network_interface.dart`) under the key `networkInterface`, as
they carry the Tor exit country, so every seam that takes the site's proxy
takes it too: the webview's store, a nested screen, a popup, a wake's
headless check and the app's own fetches for the site. The cases are
`SystemRouting` (the default, written as no key, so every existing site
reads and writes exactly as before), a `NamedInterface` holding an
`InterfaceName`, and `UnreadableInterface` for a stored value this build
cannot read. Android's transport choice is a case of its own when its phase
lands.

The choice SHALL be applied in one place, `OutboundProxy.resolved`, through
`egressRoute` (`lib/services/egress_route_engine.dart`). No consumer SHALL
read the stored field to decide a route.

A stored choice this build cannot read SHALL refuse under NETIF-002 and
SHALL be written back as it came. It SHALL NOT read as `SystemRouting`.

#### Scenario: An existing site follows the system's routing

**Given** a site saved before this change
**When** it is loaded and saved again
**Then** its choice is `SystemRouting`
**And** its proxy settings JSON carries no `networkInterface` key

#### Scenario: A choice from a newer build is not dropped

**Given** a backup whose site "Acme" carries `{"transport": "vpn"}` as its
interface
**When** it is imported by this build with the experiment on
**Then** "Acme" has no route
**And** saving "Acme" writes the same value back

---

### Requirement: NETIF-002 - A bound site refuses rather than falls back

While a site names an interface and the experiment is reachable, no
connection made for the site SHALL leave by any other interface. If no relay
runs, the route SHALL go nowhere (`ProxyType.SAVED` with no address, which
every seam refuses). If the interface is absent, down, or holds no address of
the destination's family when a connection is dialled, the relay SHALL refuse
it (SOCKS5 reply 3, network unreachable). It SHALL NOT be dialled by the
system's routing table.

#### Scenario: The tunnel is down

**Given** site "Acme" names `ws-ega`
**And** `ws-ega` is down
**When** "Acme" connects to `198.51.100.7`
**Then** the relay answers network unreachable
**And** the kernel asks no link for `198.51.100.7`

#### Scenario: No relay runs

**Given** the experiment is on and the relay did not start
**When** a site that names `wg0` resolves its route
**Then** the route goes nowhere

---

### Requirement: NETIF-003 - The binding is the platform's interface primitive, never a source address

The relay SHALL bind each outbound socket to the interface before it connects,
with the platform's interface primitive: `SO_BINDTODEVICE` on Linux
(`linux/egress_relay_core.cc`), Network.framework's `requiredInterface` (or
`IP_BOUND_IF`) on macOS and iOS, `Network.bindSocket` on Android. Binding only
the source address SHALL NOT be used: on Linux's weak host model a packet
carrying the tunnel's address as its source still leaves by the route its
destination selects.

The choice SHALL be offered only where the primitive works. On Linux the app
SHALL probe once per run by binding a socket to the loopback device; a refusal
(`EPERM`, a kernel before 5.7 without `CAP_NET_RAW`) SHALL leave the
Experimental switch and the row absent.

#### Scenario: Another link carries the route

**Given** links `ws-ega` and `ws-egb`, and a route to `198.51.100.0/24` by
`ws-egb` only
**And** site "Acme" names `ws-ega`
**When** "Acme" connects to `198.51.100.7`
**Then** the kernel asks `ws-ega` for `198.51.100.7`, and not `ws-egb`

#### Scenario: A source-address bind is the planted mistake

**Given** the relay binds the socket to `ws-ega`'s address instead of the
device
**When** the scenario above runs
**Then** `test/linux/egress_relay/check.sh` fails, because `ws-egb` is asked

---

### Requirement: NETIF-004 - A bound site rides the relay, and its credential carries the route

A site whose choice is `SystemRouting` SHALL keep the binding it has without
this change: its own store proxy on Linux and Apple (PROXY-026), and the
process rule or the router on Android. A site that names an interface SHALL
resolve to SOCKS5 at the relay, a loopback listener on a random address in
127/8 (PROXY-024).

The credential SHALL carry the whole route, so the relay keeps no table and no
route can be asked for before it is installed: the username names the
interface and any upstream (`ws-egress-1?if=<link>[&t=&h=&p=&u=]`, each value
percent-encoded), the password is the relay's per-run secret followed by the
upstream's password. A credential RFC 1929 cannot carry (255 bytes of each)
SHALL be no route. A caller that presents no credential, or a wrong secret,
SHALL be refused (LEAK-009). `test/fixtures/egress_credentials.tsv` holds the
Dart writer and the relay's reader to the same vectors.

#### Scenario: An unbound neighbour is untouched

**Given** two sites, "Acme" naming `wg0` and "Bolt" on System routing
**When** both resolve their routes
**Then** "Acme" resolves to SOCKS5 at the relay
**And** "Bolt" resolves to exactly what it did before

#### Scenario: A wrong secret

**Given** the relay is running
**When** a caller presents a credential with another secret
**Then** the relay refuses it at authentication

---

### Requirement: NETIF-005 - A proxy is dialled over the interface

When a bound site's traffic also resolves to a SOCKS5 or HTTP proxy (its own,
a library entry, or the global proxy through DEFAULT under LEAK-001), the
relay SHALL dial that proxy over the interface and hand it the destination's
name unresolved. An HTTPS proxy, whose TLS the relay does not run yet, SHALL
have no route over an interface.

#### Scenario: VPN, then proxy

**Given** site "Acme" names `wg0` and has SOCKS5 proxy `10.64.0.1:1080` with
user `alice`
**When** "Acme" loads `https://site.test/`
**Then** the relay connects to `10.64.0.1:1080` over `wg0`
**And** asks it for `site.test:443` as a name, signed in as `alice`

---

### Requirement: NETIF-006 - Tor and the interface

A site whose route resolves to Tor SHALL NOT take an interface: its first hop
is the Tor client on loopback, which no interface can bind. Its route SHALL go
nowhere while both are set. The row SHALL be locked, with the reason, while
the site names no interface; while it names one, the row SHALL offer only
System routing, so the user can always let the site go.

The built-in Tor client (iOS, macOS) MAY dial the network over an interface
chosen app-wide, by an `HTTPSProxy` naming the relay's route for that
interface. The app SHALL NOT configure an external Tor daemon (TOR-025).

#### Scenario: A Tor site's row

**Given** site "Acme" has proxy type TOR and System routing
**When** its Network screen opens
**Then** the Network interface row is disabled
**And** its subtitle says Tor makes its own connections

---

### Requirement: NETIF-007 - Names go through the interface or not at all

When the relay dials a bound site's destination itself, it SHALL resolve the
name through the interface: on Linux, systemd-resolved's `ResolveHostname`
with the interface's index, which asks only that link's servers. Where that is
unavailable, the connection SHALL be refused; the system resolver SHALL NOT be
asked. An onion name SHALL be refused without asking any resolver (LEAK-016).

#### Scenario: The link's own servers

**Given** a resolver that answers `echo.test` only when asked on the
loopback link
**When** a site bound to `lo` connects to `echo.test`
**Then** the relay reaches it

#### Scenario: No resolver

**Given** no systemd-resolved on the system bus
**When** a bound site connects to `echo.test`
**Then** the relay answers host unreachable

---

### Requirement: NETIF-008 - A bound site counts as routed for the WebRTC floor

A site whose interface is applied SHALL count as routed wherever a proxied
site does: Tracking Protection raises its stored Default WebRTC policy to
Relay only (ETP-031). Its resolved route names the relay, so the rule that
reads the route reads it unchanged; a screen asks `appliesInterface`.

The row's hint SHALL say that WebRTC calls do not take the interface.

#### Scenario: The floor applies with no proxy

**Given** site "Acme" names `wg0`, has no proxy, and has Tracking Protection on
**And** its WebRTC policy is Default
**When** its webview is built
**Then** it runs Relay only

---

### Requirement: NETIF-009 - Every connection made for the site takes the interface

Every webview that runs as the site SHALL take the site's interface through
its `SitePosture` (NESTED-010): its own webview, a nested screen, a popup, and
a wake's headless check (NOTIF-016). So SHALL every connection the app opens on
the site's behalf (an icon, a title, a user script, a download), through the
`OutboundProxy` its outbound API already requires (LEAK-002, BUG-030).

#### Scenario: A nested screen

**Given** site "Acme" names `wg0`
**When** a link opens a nested screen for "Acme"
**Then** the nested webview's store names the relay with "Acme"'s credential

---

### Requirement: NETIF-010 - The row lists what is present and keeps what is stored

While the experiment is reachable, the per-site Network screen SHALL hold a
"Network interface" row in its "Connection" group (NET-001). It SHALL offer
System routing, then each interface present now except loopback. A stored
interface that is absent now SHALL be listed as not connected and SHALL stay
chosen. The subtitle SHALL state the chosen interface's addresses, or that it
is not connected; the explanation SHALL go in the hint (settings-hints).

#### Scenario: The saved tunnel is gone

**Given** site "Acme" names `tun9`
**And** `tun9` is not present
**When** the Network screen opens
**Then** the row reads `tun9, not connected`

---

### Requirement: NETIF-011 - A process-wide rule carries one egress

Where one rule covers the process (PROXY-008, `ProcessRoute`), two sites whose
interfaces differ SHALL be two routes, as two proxies are. Their resolved
routes name the relay with different credentials, so `ProxyConflictEngine`'s
comparison of route keys tells them apart unchanged.

On Android, while a VPN is up, a site that names another network SHALL be
refused when the platform refuses `bindSocket` (a VPN that neither allows
bypass nor excludes the app).

#### Scenario: Two sites on two interfaces

**Given** site "Acme" names `wg0` and site "Bolt" names `tun0`
**When** both resolve their routes
**Then** their route keys differ, and each differs from an unbound site's

---

### Requirement: NETIF-012 - A backup carries the choice; a QR share does not

A backup SHALL carry the choice inside the site's proxy settings. A QR share
SHALL NOT, since an interface name means nothing on another device: the
encoder strips it from the proxy settings, and the decoder drops it from a
payload that carries one anyway.

#### Scenario: Shared by QR

**Given** site "Acme" names `wg0`
**When** its settings are shared as a QR code
**Then** the payload's proxy settings carry no interface

---

### Requirement: NETIF-013 - Experimental

The feature SHALL be reachable only while developer mode and the Network
interface per site switch in the Experimental group are both on (DEVTOOLS-011),
and only where the platform binds an interface (NETIF-003). The switch SHALL
default off. While it is off, a stored interface SHALL be kept and SHALL NOT
be applied, and the Network screen SHALL show no row. The relay SHALL start
when the feature becomes reachable and run until the app exits, so a site
built on it keeps its route.

#### Scenario: The switch is off

**Given** site "Acme" names `wg0`
**And** the Network interface per site switch is off
**When** "Acme" resolves its route
**Then** the route is the one its proxy settings name without the interface
**And** the Network screen shows no Network interface row

---

### Requirement: NETIF-014 - An import says which interfaces this device lacks

An import whose sites name an interface absent on this device SHALL say so
after it lands, in the shape of an imported proxy without its password, so
the user learns why those sites load nothing.

#### Scenario: Restored on another machine

**Given** a backup in which site "Acme" names `wg0`
**And** this device has no `wg0`
**When** the backup is imported
**Then** a notice names the sites whose interface is missing
