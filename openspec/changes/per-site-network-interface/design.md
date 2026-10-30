## Context

A site's traffic is routed today by its proxy alone. On Linux and Apple, each
container's store carries that proxy (PROXY-027, `ProxyBinding.perSite`); on
Android one process-wide rule does, or a loopback relay in router mode
(PROXY-008, PROXY-013). The route is resolved in one place,
`OutboundProxy.resolved` (`lib/services/outbound_http_types.dart`), and reaches
the webview through `SitePosture.container.proxy` and every Dart-side fetch
through the `proxy:` every outbound API requires (LEAK-002, BUG-030).

Nothing chooses the interface. Every connection follows the system's routing
table, so a site cannot be held to one tunnel among several, and a tunnel that
drops sends the site out by the default route.

## Goals and non-goals

- **Goal:** a per-site interface that every connection made for the site
  leaves by, refused when that interface cannot carry it.
- **Goal:** it composes with what a site already has: a proxy, the WebRTC
  floor, DNS blocking, nested screens.
- **Non-goal:** routing a site through a VPN the device is not running. The
  app binds to interfaces; it does not create them.
- **Non-goal:** two VPNs at once where the OS runs one (Android, iOS).

## Decisions

### D1. A native relay dials; Dart does not

| Option | Verdict |
|---|---|
| Dart `Socket.connect(sourceAddress:)` | Rejected. It binds an address, not a device. On Linux's weak host model the packet still leaves by the route its destination selects, carrying the tunnel's address, and a router that masquerades its WAN port completes it from the real address. The relay check plants this mistake and catches it. |
| Dart sets the option | Impossible. `setOption` and `setRawOption` act on a connected socket, so they come after the SYN. |
| FFI: make the socket in C, pass its descriptor to Dart (`SCM_RIGHTS` into `ResourceHandle.toSocket()`) | Rejected. One connection's life is then split across two runtimes, and the hand-off socket is one more loopback listener to authenticate (LEAK-009). |
| **A native relay per platform** | **Chosen.** One owner per connection from accept to close, the shape Android's `ProxyRelay.kt` already has. Each platform uses its own interface primitive (D6). |

The relay speaks **SOCKS5**, not CONNECT: WPE's network session and the Dart
outbound client already take a SOCKS5 proxy with credentials (the per-site
SOCKS5 path), so a bound site's route is an ordinary SOCKS5 route and no
consumer changes. On Linux it is `linux/egress_relay_core.cc`, a thread per
connection behind the `egress_relay` channel (`linux/egress_relay.cc`).

### D2. The choice rides `UserProxySettings`, as the Tor exit country does

`UserProxySettings.leavesBy` holds the choice, serialised as
`networkInterface` inside the site's proxy settings. The precedent is
`torExitCountry`, which lives there "so it rides the same proxySettings object
every outbound seam already receives". So:

- no new `SiteField`, no `SitePosture` field and no new parameter: the
  posture's `container.proxy`, the nested screen, popups, the headless check,
  and every outbound API's `proxy:` already carry the settings;
- `OutboundProxy.resolved` stays the one resolution rule. It resolves the
  proxy as before, then applies the interface last through `egressRoute`
  (`lib/services/egress_route_engine.dart`, pure):

| `leavesBy` | Experiment | Proxy resolves to | The route |
|---|---|---|---|
| `SystemRouting` | any | anything | as before |
| named | off (`EgressOff`) | anything | as before; the choice is kept (NETIF-013) |
| named | on, no relay (`EgressDown`) | anything | nowhere (NETIF-002) |
| named | on, relay up (`EgressUp`) | DEFAULT, no global proxy | SOCKS5 to the relay, direct over the interface |
| named | on, relay up | SOCKS5 or HTTP (own, library or global) | SOCKS5 to the relay, that proxy over the interface |
| named | on, relay up | TOR, HTTPS, unresolved library entry | nowhere (NETIF-005, NETIF-006) |

Which proxy types the relay carries is one enum, `UpstreamCarriage`, which the
resolver and the Network screen's lock both read. The resolved route names the
relay, so the rules that read a route (the WebRTC floor of ETP-031, the route
keys of PROXY-008) read a bound site as routed, and two interfaces as two
routes, with no edit.

### D3. The stored value is a sealed choice

`InterfaceChoice` (`lib/settings/network_interface.dart`): `SystemRouting`
(no key written, so every existing site's JSON is unchanged), `NamedInterface`
over an `InterfaceName` (an extension type: 1 to 15 of `[A-Za-z0-9._-]`), and
`UnreadableInterface`, a value this build cannot read, which refuses and is
written back as it came. Android's transport case joins with its phase.

- Backups carry it inside the proxy settings. A QR share does not: the encoder
  strips it and the decoder drops it (NETIF-012).
- Archive tier (ARCH-006): it is configuration, with no disk residue, no OS
  UI and no per-site entry outside the site's JSON, so archive sites may use it.

### D4. The credential carries the route, so the relay keeps no table

The username is `ws-egress-1?if=<link>[&t=socks5|http&h=<host>&p=<port>[&u=<user>]]`,
each value percent-encoded; the password is the relay's per-run secret,
followed by `.` and the upstream's password when it has one. The relay checks
the secret, parses the route and dials it, so:

- there is no route table, no install step and no ordering between an install
  and a webview build: a route that resolves is a route the relay serves;
- the relay is a static function of its secret, which Dart mints once per run
  (`Random.secure`) and never persists;
- `test/fixtures/egress_credentials.tsv` holds both sides of the string: the
  Dart test that `egressRoute` writes each vector, the relay harness that it
  reads each back.

The relay checks the interface at each dial: present, up, and holding an
address of the destination's family. A device-bound socket is never rerouted,
so a tunnel that drops fails its open connections and refuses the next.

### D5. DNS goes through the interface or nowhere

The relay receives names, because a SOCKS5 client (GIO's, and the
`socks5_proxy` package's) hands the proxy the destination unresolved. For a
direct dial the relay resolves them itself:

| Platform | Resolution | Without it |
|---|---|---|
| Linux (built) | systemd-resolved's `ResolveHostname(ifindex, name, family, flags)` with the interface's index, which asks only that link's servers; a user-named server is open question 4 | refuse |
| Android | `Network.getAllByName`, which resolves on that network | (always available) |
| macOS, iOS | `NWConnection` to a host endpoint under `requiredInterface` | to be measured (open question 1); until then, refuse direct dials and allow only a proxy upstream |

Behind a proxy the target hostname goes to the proxy, which resolves it
(LEAK-006). Only the proxy's own hostname is resolved locally, through the
interface, by the same rule.

### D6. What each platform can name, and how it binds

| | Linux | macOS | iOS | Android |
|---|---|---|---|---|
| The choice names | an interface (`wg0`, `tun0`) | an interface (`utun4`, `en0`) | an interface (Wi-Fi, cellular, the VPN's tunnel) | a transport (VPN, Wi-Fi, cellular, Ethernet) |
| Binds with | `SO_BINDTODEVICE` before `connect` | `requiredInterface`, or `IP_BOUND_IF` / `IPV6_BOUND_IF` | `requiredInterface` | `Network.bindSocket` in `ProxyRelay.kt` |
| Several tunnels at once | yes | yes | one VPN | one VPN |
| Offered when | the kernel takes the option unprivileged (Linux 5.7 and later; earlier needs `CAP_NET_RAW`) | a store takes a proxy (macOS 14) | a store takes a proxy (iOS 17) | the relay runs (router mode, or the PROXY-021 relay as the one process rule) |
| Listed from | `getifaddrs`, over the relay's channel (it reports whether a link is up, which `NetworkInterface.list()` does not) | `NWPathMonitor` | `NWPathMonitor` | `ConnectivityManager` networks, over the relay plugin's channel |

- **Linux:** a socket bound to a tunnel device sends through it even where no
  route names the device, and its sends fail once the device is gone. Probe at
  startup: bind a throwaway socket to `lo`. `EPERM` means an older kernel, and
  the row is absent.
- **Android:** while a VPN is up, an app reaches an underlying network only if
  the VPN allows bypass (`VpnService.Builder.allowBypass`) or excludes the app.
  Otherwise `bindSocket` is refused, the relay refuses the connection, and the
  picker marks Wi-Fi and cellular as held by the VPN.
- **iOS:** the useful choices are the VPN versus the physical interfaces. With
  one VPN at a time, a per-site exit country remains a per-site proxy.

### D7. A proxy rides the interface; Tor is app-wide

- **Proxy plus interface:** the relay dials the proxy over the interface, so
  the chain is device, then interface, then proxy, then origin. The proxy's
  password rides the relay credential in memory, as a per-site SOCKS5
  password already rides WPE's proxy URI on Linux; it is never serialised
  (PWD-005).
- **A TOR site:** its first hop is the Tor client on loopback, which no
  interface can bind. Its route goes nowhere while both are set, and the row
  says why (D9).
- **The built-in Tor client** (iOS, macOS) dials the network itself. Its
  connections can ride an interface app-wide by giving tor an `HTTPSProxy`
  (and `HTTPSProxyAuthenticator`) naming the egress relay's route for that
  interface. One tor serves every site, so this is one App settings choice,
  not a per-site one (phase 4).
- **External Tor** is the user's daemon. The app does not configure it, and
  the Network screen says so.
- When the VPN is the system's default route, Tor already runs over it with no
  setting, which is the #476 case.

### D8. A process-wide rule carries one egress

Where one rule covers the process (Android outside router mode,
`ProcessRoute`, PROXY-008), two sites whose interfaces differ are two routes,
as two proxies are. Their resolved routes name the relay with different
credentials, so `ProxyConflictEngine`'s route keys tell them apart with no
edit. `activation.tla`'s `Route` is a constant per site that the code
computes, so the model's text is unchanged, and with no route table there is
no new await in the activation for it to take.

### D9. The row, behind the experiment

- The feature is an Experimental switch, Network interface per site
  (`ExperimentalFeature.networkInterface`, DEVTOOLS-011), listed only where
  the probe says the platform binds (NETIF-013). The relay starts when the
  feature becomes reachable and runs until the app exits.
- On the per-site Network screen, NET-001's "Connection" group, a
  `ChoiceTile`: System routing, then each interface present now except
  loopback (`EgressRelay.links`), then a stored interface that is absent now,
  as "wg0, not connected".
- The subtitle carries the state: the interface's addresses, or not connected.
- The hint carries the explanation: what binding does, that it refuses rather
  than falls back, the DNS rule, that a proxy above is reached through it, and
  that WebRTC calls do not take it.
- A route the relay cannot carry (Tor, an HTTPS proxy) locks the row while
  the site names no interface; while it names one, only System routing can be
  picked, so a site the combination blocks can always be let go.

## Risks and trade-offs

- **A userspace hop per byte.** The relay copies every byte once. Android's
  router already pays this (`Splicer.kt`), and only bound sites pay it.
- **The relay is a new listener.** It takes a per-run secret, as the router
  takes a token (PROXY-023), on an unguessable loopback address (PROXY-024).
  A caller without the secret is refused before any dial.
- **An interface name can be reused by another tunnel.** OpenVPN's `tun0`
  names whichever config ran last. On macOS, `utun` numbers are assigned when
  a tunnel starts, and wg-quick maps its `wg0` to whichever one it got. A
  binding by name can then carry the site through a different VPN, which is
  not a leak of the real address but is the wrong exit (open question 2).
- **WebRTC.** UDP never reaches the relay, which serves SOCKS5 CONNECT only. A bound site therefore takes
  the proxied-site floor, and its TURN traffic still follows the system
  routing table. That is the same gap LEAK-005 names for proxies, and the
  hint says it.

## Phases

1. **Linux, built.** The type, the route rule, the relay with its native
   check (`test/linux/egress_relay/check.sh`, in CI's Linux job), DNS through
   resolved, the row and the Experimental switch.
2. **macOS.** `EgressRelay.swift` over Network.framework, after open
   question 1 is measured.
3. **Android and iOS.** The transport choice on Android in `ProxyRelay.kt`,
   and the VPN-versus-physical choice on iOS.
4. **Built-in Tor over an interface**, app-wide (D7).

## Open questions

1. **Does `requiredInterface` scope name resolution on Apple?** Apple's
   reference for `NWParameters.requiredInterface` says connections use the
   interface. It does not say whether the resolver's queries do too. Measure
   it on a device, capturing on the tunnel and on `en0`, before phase 2 allows
   a direct dial.
2. **Pin more than the name?** Record the addresses the interface held when
   chosen and refuse a same-named interface holding none of them. This catches
   a reused name, but some providers hand out a new address on each connect.
   Decide with phase 2, where `utun` makes it common.
3. **An app-wide interface that sites follow**, as DEFAULT follows the global
   proxy. The global proxy is a `UserProxySettings` too, so it can carry one;
   what is open is the row and whether a site's own choice overrides it.
4. **A DNS server the user names**, queried over a socket bound to the
   interface, for a Linux system without systemd-resolved, where a bound site
   now refuses every name.
