# Per-site network interface

## Why

[Discussion #477](https://github.com/theoden8/webspace_app/discussions/477)
asks for qBittorrent's "Network Interface" setting, per site: site A leaves by
a VPN with a US address, site B by a VPN with a French one, and a site bound
to an interface that is down loads nothing rather than falling back to the
default route. [#476](https://github.com/theoden8/webspace_app/discussions/476)
adds the case behind it: the VPN stays on at all times and only some sites
take Tor on top of it.

What the app has today covers part of this, by a different mechanism:

| Want | Today |
|---|---|
| A different exit country per site | A per-site SOCKS5/HTTP proxy (PROXY-001), from the proxy library (PROXY-030). Several VPN providers serve a SOCKS5 proxy inside their tunnel, and a WireGuard config can be served as SOCKS5 by a userspace client. |
| Refuse rather than leak when the route is gone | The proxy paths fail closed (LEAK-003, PROXY-022, PROXY-016). |
| Tor over an always-on VPN | Built-in Tor on iOS and macOS, external Tor elsewhere (TOR-025). Tor runs over the VPN whenever the VPN is the default route. |
| Bind a site to an interface | Nothing. No code calls an interface primitive (`SO_BINDTODEVICE`, `requiredInterface`, `bindSocket`). |

The gap is the last row: a route chosen by interface instead of by proxy, so
a VPN that offers no proxy endpoint (a WireGuard or OpenVPN tunnel from any
provider, or the user's own) can carry one site and not another.

## What Changes

- **A new `network-interface` capability** (NETIF-001 to NETIF-011): a per-site
  choice of the interface the site's traffic leaves by, `System routing` by
  default.
- **Fail closed.** A site bound to an interface that is absent, down or has no
  address of the needed family gets a refused connection and a page that says
  why, never the default route (NETIF-002).
- **A native egress relay per platform.** The site's store proxy names a
  loopback relay, and the relay dials out with the platform's interface
  primitive: `SO_BINDTODEVICE` on Linux, Network.framework's
  `requiredInterface` on iOS and macOS, `Network.bindSocket` on Android
  (NETIF-003, NETIF-004). Only sites bound to an interface go through it;
  every other site keeps the binding it has now.
- **The interface carries what the site already has.** A proxy is dialled over
  the interface (NETIF-005). DNS for a direct dial is resolved through the
  interface (NETIF-007). WebRTC follows the proxied-site floor (NETIF-008).
- **Every connection made for the site takes it**: nested screens, popups, a
  wake's headless check, and the app's own fetches for the site (NETIF-009).
- **The join that carries it is `OutboundProxy`**, which already reaches every
  outbound API and the webview's proxy. It gains the interface, so no new
  parameter is threaded anywhere (design D2).

## The decision this change makes, and why

**The relay binds the interface; Dart and the source address do not.** Dart's
`Socket.connect` takes a `sourceAddress` but sets no option before the
connection starts, so it cannot bind to a device. Binding only the source
address is not a substitute. Linux uses the weak host model, so a packet
carrying the tunnel's address as its source still leaves by the default route.
A router that masquerades whatever crosses its WAN port then completes that
connection from the user's real address. That is the leak this feature exists
to prevent.

**Only interface-bound sites ride the relay.** PROXY-026 keeps Apple off router
mode because a relay in front of a per-store proxy only adds a hop. An
interface binding is the one thing a store cannot express, so it is the one
case where a store names a loopback relay. Every other site is left as it is.

## Scope

**In.** Linux first: interfaces by name, any number of tunnels at once. Then
macOS, which can also carry several tunnels at once. Then Android and iOS,
where the choice is narrower (design D6).

**In, app-wide only.** The built-in Tor client's own connections over a chosen
interface (NETIF-006, phase 4). One Tor client serves every site, so this is
not per site.

**Out.** Two VPNs at once on Android or iOS: each runs one VPN at a time. There,
a per-site exit country stays a per-site proxy reached through the one VPN.

**Out.** An app-wide default interface that sites follow, as DEFAULT follows
the global proxy. It is a `Scoped` value on top of this change and can come
after it.

**Out.** Choosing the interface for external Tor. That tor daemon belongs to
the user, and so does its configuration (`OutboundBindAddress`, a network
namespace).

## Impact

- New: `openspec/specs/network-interface/spec.md` (on archive).
- `lib/settings/site_field.dart`, `lib/web_view_model_json.dart`: one
  `SiteField` (backups carry it; a QR share does not).
- `lib/services/outbound_http_types.dart`: `OutboundProxy` and `ProxyRoute`
  carry the interface. This is a join in the CLAUDE.md map, so it is flagged
  for review.
- `lib/services/proxy_relay.dart`: the route wire shape gains `interface`;
  `ProxyRelayApi` is unchanged.
- Native relays: `linux/egress_relay.cc` (new),
  `macos/Runner/EgressRelay.swift` and its iOS twin (new), and
  `android/.../proxy/ProxyRelay.kt` (dial through `Network`).
- `lib/screens/site_network.dart`: a "Network interface" row (NET-001's
  "Connection" group).
- `lib/services/proxy_conflict_engine.dart`: two sites whose interfaces differ
  are two routes (PROXY-008), so a process-wide rule cannot carry both.
- `lib/settings/location.dart` `resolveWebRtcPolicy`: "proxied" becomes
  "routed".
- `openspec/specs/ip-leakage/spec.md` LEAK-007 (coverage matrix) and
  `openspec/specs/proxy/spec.md` PROXY-026 (the store-relay exception), on
  archive.
- `lib/l10n/app_*.arb`: the row, its hint, the blocked page and the import
  notice, translations in their own commit.
