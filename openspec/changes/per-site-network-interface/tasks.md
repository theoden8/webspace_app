## 1. Specify

- [x] 1.1 `specs/network-interface/spec.md`: NETIF-001 to NETIF-014.
- [x] 1.2 `design.md`: the native SOCKS5 relay (D1), the choice on
  `UserProxySettings` (D2), the credential that carries the route (D4), the
  platform matrix (D6), the phases and the open questions.
- [x] 1.3 List what no check names yet in `openspec/unverified.tsv`.
- [x] 1.4 Add the `network-interface` row, marked *(change)*, to the OpenSpec
  table in `CLAUDE.md`.

## 2. The type and the route (every platform)

- [x] 2.1 `InterfaceChoice` (sealed) and `InterfaceName` (extension type, with
  `parse`), in `lib/settings/network_interface.dart`.
- [x] 2.2 `UserProxySettings.leavesBy`, written as `networkInterface` only when
  set; a present value that does not parse reads as unavailable (NETIF-001).
- [x] 2.3 `egressRoute` and `UpstreamCarriage` in
  `lib/services/egress_route_engine.dart`, applied last by
  `OutboundProxy.resolved`; the Tor copy in `OutboundProxy.ofSite` keeps the
  choice (a planted drop of it fails NETIF-006's test).
- [x] 2.4 The Network screen's WebRTC floor reads `appliesInterface`
  (NETIF-008); the webview's reads the resolved route unchanged.
- [x] 2.5 Two interfaces are two route keys (NETIF-011), by construction.
- [x] 2.6 `superset.json`: the experiment's pref.
- [x] 2.7 The Experimental switch (`ExperimentalFeature.networkInterface`,
  NETIF-013), listed only where the probe says the platform binds.

## 3. Linux (phase 1)

- [x] 3.1 `linux/egress_relay_core.cc`: a SOCKS5 relay on a random 127/8
  address, a thread per connection, `SO_BINDTODEVICE` before `connect`, the
  link checked at each dial; `linux/egress_relay.cc`: the `egress_relay`
  channel (`probe`, `links`, `start`, `stop`).
- [x] 3.2 DNS through systemd-resolved's `ResolveHostname(ifindex, ...)`;
  refuse without it; refuse an onion name (NETIF-007).
- [ ] 3.2b A DNS server the user names, queried over a socket bound to the
  interface (design open question 4).
- [x] 3.3 The startup probe (bind a socket to `lo`), read by the switch and
  the row (NETIF-003).
- [x] 3.4 `test/linux/egress_relay/check.sh`, run by CI's Linux job: two veth
  links with a route by B only; a connection bound to A must ask A for its
  destination. Seven planted mistakes, among them a source-address bind,
  each caught.
- [x] 3.5 The credential vectors both sides are held to
  (`test/fixtures/egress_credentials.tsv`).
- [x] 3.6 Dart-side fetches take the relay through the route they already
  resolve. LEAK-007's matrix gains its rows on archive.
- [ ] 3.7 A blocked page that names the interface (NETIF-002 refuses; WPE
  shows its own error for now).
- [x] 3.8 The row on `site_network.dart` (NETIF-010), its hint, and the Tor
  and HTTPS lock (NETIF-006). Code and `app_en.arb` first, the 66
  translations in their own commit.
- [ ] 3.9 The post-import notice (NETIF-014).
- [ ] 3.10 A test that drives a nested screen, a popup, a headless check and
  an icon fetch for a bound site (NETIF-009).

## 4. macOS (phase 2)

- [ ] 4.1 Measure open question 1 on a device: a direct dial under
  `requiredInterface`, captured on the tunnel and on `en0`.
- [ ] 4.2 `macos/Runner/EgressRelay.swift`: `NWListener` and `NWConnection`
  with `requiredInterface`. Treat `.waiting` as refused after the dial
  timeout. Run `tool/swift_typecheck/check.sh`.
- [ ] 4.3 Decide open question 2 (pin addresses as well as the name).
- [ ] 4.4 Amend PROXY-026: a bound site's store names the egress relay.

## 5. Android and iOS (phase 3)

- [ ] 5.1 `ProxyRelay.kt`: a route's `AndroidNetwork` resolves to a live
  `Network` at each dial, is bound with `bindSocket`, and is resolved with
  `getAllByName`. A refusal under a VPN without bypass refuses the
  connection (NETIF-011).
- [ ] 5.2 The networks list over the relay plugin's channel, marking networks
  held by a VPN.
- [ ] 5.3 iOS: the shared Swift relay, with the choice listed by
  `NWPathMonitor`.

## 6. Built-in Tor over an interface (phase 4)

- [ ] 6.1 An App settings choice, giving tor an `HTTPSProxy` and an
  `HTTPSProxyAuthenticator` that name the relay's route for it (NETIF-006).

## 7. Archive

- [ ] 7.1 Move the spec to `openspec/specs/network-interface/`, drop the
  *(change)* mark in `CLAUDE.md`, and empty this change's lines from
  `unverified.tsv` as their checks land.
