## 1. Specify

- [x] 1.1 `specs/network-interface/spec.md`: NETIF-001 to NETIF-012.
- [x] 1.2 `design.md`: the native relay (D1), the `OutboundProxy` join (D2),
  the platform matrix (D6), the phases and the open questions.
- [x] 1.3 List NETIF-001 to NETIF-012 in `openspec/unverified.tsv` until a
  check names each.
- [x] 1.4 Add the `network-interface` row, marked *(change)*, to the OpenSpec
  table in `CLAUDE.md`.

## 2. The type and the field (every platform)

- [ ] 2.1 `InterfaceChoice` (sealed) and `InterfaceName` (extension type, with
  `parse`), in `lib/settings/`.
- [ ] 2.2 One `SiteField` case with `qr: false`, and its save and read arms in
  `web_view_model_json.dart`. An absent key reads as `SystemRouting`; a
  present value that does not parse reads as unavailable (NETIF-001).
- [ ] 2.3 `OutboundProxy.ofSite(stored, site:, leavesBy:)` and
  `ProxyRoute.leavesBy` (D2). Every `ofSite` call site names `leavesBy:`, so
  a forgotten one fails to compile.
- [ ] 2.4 `resolveWebRtcPolicy(proxied:)` becomes `routed:`, read off the
  `ProxyRoute` (NETIF-008).
- [ ] 2.5 `ProxyConflictEngine` compares the route including `leavesBy`
  (NETIF-011). Test: two sites differing only by interface conflict.
- [ ] 2.6 `superset.json` and the compat test: the new key.

## 3. Linux (phase 1)

- [ ] 3.1 `linux/egress_relay.cc`: a GLib loopback CONNECT relay behind
  `ProxyRelayApi` on its own channel, reading the route table's `interface`.
  It binds each socket with `SO_BINDTODEVICE` before `connect`, checks that
  the interface is present and up and has an address of the family at each
  dial, and refuses otherwise (NETIF-002, NETIF-003, NETIF-004).
- [ ] 3.2 DNS through systemd-resolved's `ResolveHostname(ifindex, ...)`, or
  through a user-named server queried over a bound UDP socket; refuse without
  either (NETIF-007).
- [ ] 3.3 The startup probe (bind a socket to `lo`) and its witness, read by
  the row and by `OutboundProxy` (NETIF-003).
- [ ] 3.4 Boundary test in its own network namespace under `sudo`, in the
  linux CI job. Two veth links reach two peer namespaces, each serving its own
  name, with the default route on link B. The test asserts:
  - bound to A, the relay reaches A;
  - with A down, it refuses, and B sees no SYN.

  Planted mistake: a source-address bind instead of the device bind, which
  this test must fail (NETIF-003).
- [ ] 3.5 The store proxy names the relay with the site's credential, and the
  build takes `EgressRouted` (NETIF-004). The install is a
  `SiteSetChange.effects` step. If the build waits on it, it is a `Step` of
  the activation table: run `./formal/verify.sh` before pushing.
- [ ] 3.6 Dart-side fetches: `OutboundHttpFactory.clientFor` routes a bound
  `ProxyRoute` through the relay (NETIF-009), and LEAK-007's matrix gains its
  rows.
- [ ] 3.7 The blocked page (NETIF-002).
- [ ] 3.8 The row on `site_network.dart` (NETIF-010), its hint, and the TOR
  lock (NETIF-006). Code and `app_en.arb` first, the 66 translations in their
  own commit.
- [ ] 3.9 The post-import notice (NETIF-012).

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
  `HTTPSProxyAuthenticator` that name the egress relay's route for it
  (NETIF-006).

## 7. Archive

- [ ] 7.1 Move the spec to `openspec/specs/network-interface/`. Drop the
  *(change)* mark in `CLAUDE.md`, add the `InterfaceChoice` row to the
  CLAUDE.md map, and empty this change's lines from `unverified.tsv` as their
  checks land.
