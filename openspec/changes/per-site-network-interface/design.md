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
| Dart `Socket.connect(sourceAddress:)` | Rejected. It binds an address, not a device. On Linux's weak host model the packet still leaves by the default route, carrying the tunnel's address, and a router that masquerades its WAN port completes it from the real address. |
| Dart sets the option | Impossible. `setOption` and `setRawOption` act on a connected socket, so they come after the SYN. |
| FFI: make the socket in C, pass its descriptor to Dart (`SCM_RIGHTS` into `ResourceHandle.toSocket()`) | Rejected. One connection's life is then split across two runtimes, and the hand-off socket is one more loopback listener to authenticate (LEAK-009). |
| **A native relay per platform** | **Chosen.** One owner per connection from accept to close, which is already the shape of Android's `ProxyRelay.kt`. Each platform uses its own interface primitive (D6). |

Each relay implements `ProxyRelayApi` (`lib/services/proxy_relay.dart`)
unchanged. The route wire shape gains one key, `interface`, which the relay
reads per route.

### D2. The join is `OutboundProxy`, which gains the interface

`OutboundProxy.ofSite(stored, site:)` becomes
`OutboundProxy.ofSite(stored, site:, leavesBy:)`, and `ProxyRoute` carries
`leavesBy`. `resolved` stays the one resolution rule:

| `leavesBy` | Proxy resolves to | The route |
|---|---|---|
| `SystemRouting` | anything | as today |
| an interface | DEFAULT, no global proxy | the egress relay, which dials the origin over the interface |
| an interface | a proxy (own, library or global) | the egress relay, which dials that proxy over the interface |
| an interface | TOR | refused at the setting (NETIF-006) |

Every consumer already takes an `OutboundProxy` or a `ProxyRoute`: the webview
factory's store proxy, `OutboundHttpFactory.clientFor`, `waitsForTor`, the
proxy test. So the interface reaches all of them without a new parameter, and
a new outbound path that takes `proxy:` gets it for free. The cost is a join
in the CLAUDE.md map changing shape, which this change flags for review.

### D3. The stored value is a sealed choice, read per platform

```dart
sealed class InterfaceChoice {}
final class SystemRouting extends InterfaceChoice {}
final class NamedInterface extends InterfaceChoice { final InterfaceName name; }  // Linux, macOS, iOS
final class AndroidNetwork extends InterfaceChoice { final NetworkTransport transport; } // vpn, wifi, cellular, ethernet
extension type InterfaceName._(String raw) implements String { ... parse ... }
```

- Android exposes networks, not interface names, and a `Network` handle does
  not survive a reconnect, so Android stores the transport.
- A choice of a case this platform does not offer (a backup made on Linux and
  restored on Android) is **unavailable**, which refuses. It does not mean
  system routing.
- One `SiteField` with `qr: false`, since an interface name means nothing on
  another device. Backups carry it, and an import whose interface is absent on
  this device gets a notice, as an imported proxy without its password does.
- Archive tier (ARCH-006): it is configuration, with no disk residue, no OS
  UI and no per-site entry outside the site's JSON, so archive sites may use it.

### D4. Only interface-bound sites ride the relay, and the relay checks at dial

- A store whose site has `SystemRouting` keeps exactly what it has now. Apple
  router mode stays off (PROXY-026). The relay is an exception for bound sites
  only, because a store has no setting that names an interface.
- The relay authenticates each caller by the per-run credential it already
  uses (PROXY-023, PROXY-024, LEAK-009). The credential names the site, and
  the site names the route.
- The interface is checked **at each dial**, not when the route is installed:
  present, up, and holding an address of the destination's family. A tunnel
  that drops after the page loaded fails its next connection, not some later
  rebuild.
- Connections already open on an interface that goes away fail with it. A
  device-bound socket is never rerouted, which is the kill switch.
- The route table follows the site set: installing it is an effect of
  `SiteSetChange.effects`, so a change that forgets it does not compile. A
  bound site's webview is built only with a witness that the relay holds its
  route (an `EgressRouted`, made only by the install), in the shape of the
  startup witnesses.

### D5. DNS goes through the interface or nowhere

The relay receives hostnames, because WebKit and Chromium send `CONNECT
host:port` to a proxy. For a direct dial it resolves them itself:

| Platform | Resolution | Without it |
|---|---|---|
| Linux | systemd-resolved's `ResolveHostname(ifindex, name, family, flags)` with the interface's index, which asks only that link's servers; or a DNS server the user names, queried over a socket bound to the interface | refuse |
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
| Listed from | `NetworkInterface.list()` | `NetworkInterface.list()`, `NWPathMonitor` for the kind | `NWPathMonitor` | `ConnectivityManager` networks, over the relay plugin's channel |

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
  the chain is device, then interface, then proxy, then origin. The proxy
  credential stays in the route table and is never serialised (PWD-005).
- **A TOR site:** its first hop is the Tor client on loopback, which no
  interface can bind. The row is locked with the reason (`Lock.because`), not
  silently ignored.
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
as two proxies are. `ProxyConflictEngine` compares the resolved egress (proxy
and interface), so the activation unloads the disagreeing site before the rule
flips. `activation.tla`'s `Route` is a constant per site that the code computes,
so the model's text is unchanged and `Inv_OneRoute` holds over the egress. If
the route install becomes an await inside the activation, it is a `Step` of
`ActivationTable.activationFlow` and its action is printed; `formal/verify.sh`
gates it.

### D9. The row

- On the per-site Network screen, NET-001's "Connection" group, a
  `ChoiceTile`: "System routing", then each interface present now (its name,
  its addresses, and its kind where the platform reports one), then a stored
  interface that is absent now, as "wg0 (not connected)".
- The subtitle carries the state: the interface and whether it is up, in the
  PROXY-031 style.
- The hint carries the explanation: what binding does, that it refuses rather
  than falls back, that WebRTC media does not take it (NETIF-008), and the DNS
  rule.
- The row is absent where the platform cannot bind (D6, "Offered when"), and
  locked for a TOR site.

## Risks and trade-offs

- **A userspace hop per byte.** The relay copies every byte once. Android's
  router already pays this (`Splicer.kt`), and only bound sites pay it.
- **The relay is a new listener.** It reuses the router's authentication
  (PROXY-023, PROXY-024) and its unguessable loopback address. A relay that
  cannot attribute a tunnel refuses it.
- **An interface name can be reused by another tunnel.** OpenVPN's `tun0`
  names whichever config ran last. On macOS, `utun` numbers are assigned when
  a tunnel starts, and wg-quick maps its `wg0` to whichever one it got. A
  binding by name can then carry the site through a different VPN, which is
  not a leak of the real address but is the wrong exit (open question 2).
- **WebRTC.** UDP never reaches a CONNECT relay. A bound site therefore takes
  the proxied-site floor, and its TURN traffic still follows the system
  routing table. That is the same gap LEAK-005 names for proxies, and the
  hint says it.

## Phases

1. **Linux.** The type, the field, `OutboundProxy`, the relay in
   `linux/egress_relay.cc`, the row, DNS through resolved. This is the
   platform that has the user's case, several tunnels at once, and it is the
   only one this repo's CI can exercise end to end (tasks 3.4).
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
   proxy: a `Scoped<InterfaceChoice>` on top of this change, once someone asks
   for it.
