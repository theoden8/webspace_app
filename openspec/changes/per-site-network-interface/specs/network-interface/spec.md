# Network interface

## ADDED Requirements

### Requirement: NETIF-001 - A site names the interface its traffic leaves by

A site SHALL carry an `InterfaceChoice`: `SystemRouting` (the default, and what
every existing site reads as), a `NamedInterface` on Linux, macOS and iOS, or
an `AndroidNetwork` naming a transport (VPN, Wi-Fi, cellular, Ethernet) on
Android. The choice SHALL be resolved once, into the site's `OutboundProxy`
(`OutboundProxy.ofSite(stored, site:, leavesBy:)`), and read from there by
every consumer. No consumer SHALL read the stored field.

A stored choice whose case this platform does not offer SHALL read as
unavailable, which refuses under NETIF-002. It SHALL NOT read as
`SystemRouting`.

#### Scenario: An existing site follows the system's routing

**Given** a site saved before this change
**When** it is loaded
**Then** its choice is `SystemRouting`
**And** its webview's proxy is exactly what it was before

#### Scenario: A choice from another platform is not dropped

**Given** a backup made on Linux in which site "Acme" names `wg0`
**When** it is imported on Android
**Then** "Acme"'s choice is unavailable on this device
**And** "Acme" loads nothing until the user picks a network or System routing

---

### Requirement: NETIF-002 - A bound site refuses rather than falls back

While a site names an interface, no connection made for the site SHALL leave
by any other interface. If the interface is absent, down, or holds no address
of the destination's family, the connection SHALL be refused. It SHALL NOT be
dialled by the system's routing table.

A refused main-frame load SHALL show a page naming the interface and that it
is not connected, in the shape of a blocked Tor site (PROXY-016). It SHALL NOT
show an empty page or the engine's generic network error.

#### Scenario: The tunnel is down at load

**Given** site "Acme" names `wg0`
**And** `wg0` does not exist
**When** "Acme" is opened
**Then** no connection for "Acme" leaves by any interface
**And** the page says that `wg0` is not connected

#### Scenario: The tunnel drops while the page is open

**Given** site "Acme" names `wg0` and has loaded over it
**When** `wg0` goes down and the page fetches again
**Then** the fetch is refused
**And** no SYN for it leaves by the default route

#### Scenario: An IPv4-only tunnel and an IPv6 destination

**Given** site "Acme" names `wg0`, which holds only an IPv4 address
**When** a host of "Acme" resolves only to IPv6 addresses
**Then** the connection is refused
**And** it is not dialled over another interface that has IPv6

---

### Requirement: NETIF-003 - The binding is the platform's interface primitive, never a source address

The relay SHALL bind each outbound socket to the interface before it connects,
with the platform's interface primitive:

| Platform | Primitive |
|---|---|
| Linux | `SO_BINDTODEVICE` |
| macOS, iOS | Network.framework `requiredInterface`, or `IP_BOUND_IF` / `IPV6_BOUND_IF` |
| Android | `Network.bindSocket` |

Binding only the source address SHALL NOT be used. On Linux's weak host model
a packet carrying the tunnel's address as its source still leaves by the
default route.

The choice SHALL be offered only where the primitive works. On Linux the app
SHALL probe once per run by binding a socket to the loopback device; a
refusal (`EPERM`, a kernel before 5.7 without `CAP_NET_RAW`) SHALL leave the
row absent.

#### Scenario: The default route points elsewhere

**Given** a Linux host whose default route leaves by `eth0`
**And** site "Acme" names `veth-a`, which no route names
**When** "Acme" connects to a host reachable over `veth-a`
**Then** the connection leaves by `veth-a`
**And** `eth0` carries no packet for it

#### Scenario: A source-address bind is the planted mistake

**Given** the relay's Linux dial binds the source address instead of the device
**When** the scenario above runs
**Then** the boundary test fails, because `eth0` carries the SYN

#### Scenario: An old kernel

**Given** a Linux kernel that refuses `SO_BINDTODEVICE` to an unprivileged process
**When** the per-site Network screen opens
**Then** no "Network interface" row is shown

---

### Requirement: NETIF-004 - Only bound sites ride the egress relay, which checks the interface at each dial

A site whose choice is `SystemRouting` SHALL keep the binding it has without
this change: its own store proxy on Linux and Apple (PROXY-026), and the
process rule or router on Android. A site that names an interface SHALL have
its store's proxy name the egress relay, with its per-run relay credential
(PROXY-023, PROXY-024). This is the one case where an Apple store names a
loopback relay, since no store setting names an interface.

The relay SHALL check the interface at each dial, not when the route was
installed. A bound site's webview SHALL be built only once the relay holds the
site's route; the build SHALL take the install's witness (`EgressRouted`),
which only the install makes.

#### Scenario: An unbound neighbour is untouched

**Given** two sites on macOS, "Acme" naming `utun4` and "Bolt" on System routing
**When** both are loaded
**Then** "Acme"'s store names the egress relay
**And** "Bolt"'s store names "Bolt"'s own proxy, or none, as before

#### Scenario: A caller the relay cannot attribute

**Given** the egress relay is running
**When** a connection presents no credential, or one the relay does not hold
**Then** it is refused (LEAK-009)

---

### Requirement: NETIF-005 - A proxy is dialled over the interface

When a bound site's traffic also resolves to a proxy (its own, a library
entry, or the global proxy through DEFAULT under LEAK-001), the relay SHALL
dial that proxy over the interface. The proxy then carries the request. The
upstream's credential SHALL stay in the relay's route table and SHALL NOT be
serialised (PWD-005).

#### Scenario: VPN, then proxy

**Given** site "Acme" names `wg0` and has SOCKS5 proxy `10.64.0.1:1080`
**When** "Acme" loads `https://example.com/`
**Then** the relay connects to `10.64.0.1:1080` over `wg0`
**And** sends `example.com` to the proxy unresolved

---

### Requirement: NETIF-006 - Tor and the interface

A site whose proxy resolves to TOR SHALL NOT take an interface: its first hop
is the Tor client on loopback. Its row SHALL be locked, with the reason in the
subtitle (`Lock.because`).

The built-in Tor client (iOS, macOS) MAY dial the network over an interface
chosen app-wide, by an `HTTPSProxy` naming the egress relay's route for that
interface. This SHALL be one App settings choice, since one client serves
every site. The app SHALL NOT configure an external Tor daemon (TOR-025).

#### Scenario: A Tor site's row

**Given** site "Acme" has proxy type TOR
**When** its Network screen opens
**Then** the "Network interface" row is disabled
**And** its subtitle says Tor chooses its own route

---

### Requirement: NETIF-007 - DNS for a direct dial goes through the interface or not at all

When the relay dials a bound site's origin directly, it SHALL resolve the
hostname through the interface:

| Platform | Resolution |
|---|---|
| Linux | systemd-resolved `ResolveHostname` with the interface's index, or a DNS server the user names, queried over a socket bound to the interface |
| Android | `Network.getAllByName` on the chosen network |
| macOS, iOS | only once a device measurement shows the resolver's queries leave by the required interface; until then a direct dial is refused and only a proxy upstream is allowed |

Where none is available, the connection SHALL be refused. The system resolver
SHALL NOT be asked for a bound site's host.

#### Scenario: No per-link resolver

**Given** a Linux host with no systemd-resolved on the bus
**And** site "Acme" names `wg0` with no DNS server named
**When** "Acme" loads `https://example.com/`
**Then** the connection is refused
**And** no query for `example.com` leaves by any interface

---

### Requirement: NETIF-008 - A bound site counts as routed for the WebRTC floor

A site that names an interface SHALL count as routed wherever a proxied site
does: Tracking Protection raises its stored `defaultPolicy` WebRTC policy to
`relayOnly` (ETP-031), and LEAK-005's hint is shown. "Routed" SHALL be read off
the resolved route, which names a proxy or an interface, in
`resolveWebRtcPolicy`. It SHALL NOT be restated per screen.

The hint SHALL say that WebRTC media does not take the interface: UDP never
reaches a CONNECT relay, so a TURN server sees the default route.

#### Scenario: The floor applies with no proxy

**Given** site "Acme" names `wg0`, has no proxy, and has Tracking Protection on
**And** its WebRTC policy is Default
**When** its webview is built
**Then** it runs Relay only

---

### Requirement: NETIF-009 - Every connection made for the site takes the interface

Every webview that runs as the site SHALL take the site's interface through its
`SitePosture` (NESTED-010): its own webview, a nested screen, a popup, and a
wake's headless check (NOTIF-016). So SHALL every connection the app opens on
the site's behalf (an icon, a title, a user script, a download), through the
`OutboundProxy` its outbound API already requires (LEAK-002, BUG-030).

#### Scenario: A nested screen

**Given** site "Acme" names `wg0`
**When** a link opens a nested screen for "Acme"
**Then** the nested webview's store names the egress relay with "Acme"'s credential

#### Scenario: An icon fetch

**Given** site "Acme" names `wg0`
**When** the app fetches "Acme"'s icon
**Then** the fetch goes through the egress relay
**And** it is refused while `wg0` is down

---

### Requirement: NETIF-010 - The row lists what is present and keeps what is stored

The per-site Network screen SHALL hold a "Network interface" row in its
"Connection" group (NET-001). It SHALL offer System routing, then each
interface present now with its addresses and, where the platform reports one,
its kind. A stored interface that is absent now SHALL be listed as not
connected, and SHALL stay selected. The subtitle SHALL state the choice and
whether it is up. The explanation (refusal, DNS, WebRTC) SHALL go in the hint
(settings-hints).

The row SHALL be absent where the platform cannot bind (NETIF-003), and on
Android where no relay runs.

#### Scenario: The saved tunnel is down

**Given** site "Acme" names `wg0`
**And** `wg0` is not present
**When** the Network screen opens
**Then** the row reads `wg0` and says it is not connected
**And** saving the screen keeps `wg0`

---

### Requirement: NETIF-011 - A process-wide rule carries one egress

Where one rule covers the process (PROXY-008, `ProcessRoute`), two sites whose
interfaces differ SHALL be two routes, as two proxies are.
`ProxyConflictEngine` SHALL compare the resolved route, proxy and interface
together.

On Android, while a VPN is up, a site that names another network SHALL be
refused when the platform refuses `bindSocket` (a VPN that neither allows
bypass nor excludes the app). The picker SHALL mark those networks as held by
the VPN.

#### Scenario: Two sites on two networks

**Given** Android outside router mode
**And** site "Acme" names VPN and site "Bolt" names Wi-Fi
**When** "Bolt" is activated while "Acme" is loaded
**Then** "Acme" is unloaded before the rule changes (PROXY-008)

#### Scenario: A VPN that allows no bypass

**Given** an Android VPN that does not allow bypass
**And** site "Acme" names Wi-Fi
**When** "Acme" loads
**Then** the connection is refused
**And** nothing for it leaves by the VPN either

---

### Requirement: NETIF-012 - A backup carries the choice; a QR share does not

The choice SHALL be a `SiteField` that a backup carries and a QR share does
not, since an interface name means nothing on another device. An import that
names an interface absent on this device SHALL say so after it lands, in the
shape of an imported proxy without its password.

#### Scenario: Shared by QR

**Given** site "Acme" names `wg0`
**When** its settings are shared as a QR code
**Then** the QR payload carries no interface
**And** the receiving device's copy follows the system's routing
