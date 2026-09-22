# BUG-014 — A per-site setting the Dart side sends and the native side drops

Status: **open, narrowed.** The per-site proxy on Apple works: measured on real
hardware, every store binds its own upstream and its own credential, at any
frame and on later navigations. The 101 attempts that said otherwise were
reading a broken instrument. Two instances of the seam's real defect are
fixed, a third was fixed in the fork, and the seam still has no general
guard.

**Spec:** [ip-leakage](../../openspec/specs/ip-leakage/spec.md) LEAK-003,
[proxy](../../openspec/specs/proxy/spec.md) PROXY-011,
[tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md) TOR-018
**Tests:** `integration_test/proxy_frame_ladder_test.dart` and the other
`proxy_*` arms, which read the verdict off a destination only a proxy can
reach; `test/js/proxy_binding_fixture.test.js` gates their shape.

## Symptom

A per-site setting is configured, the app reports it as applied, every
Dart-side test agrees, and the behaviour the user asked for does not happen.
The setting crossed the platform channel and was discarded on the far side
without a word.

## Root mechanism

**Nothing on either side of the channel fails when a field goes missing.** The
Dart side logs what it *sent*; the native side acts on what it *parsed*; no
assertion compares the two. `ISettings.parse` sets values reflectively behind
`responds(to:)`, so a property the Objective-C runtime cannot see is skipped
silently. Only something that observes the *effect* can catch it.

## Instances

1. **The per-site proxy was never bound on iOS/macOS.** `proxySettings` was
   typed `[String: Any?]?`, which has no ObjC representation, so it was never
   exposed and never set. Fixed.
2. **Tor's bootstrap phase was dropped at the control-event seam.** The plugin
   never read `TAG`/`SUMMARY` off `STATUS_CLIENT`. Fixed.
3. **The proxy credential was dropped on Apple, degrading Tor circuit
   isolation to per-destination.** The app wrote the credential only as URL
   userinfo (`socks5://user:pass@host:port`); `ProxyRule.toProxyConfiguration`
   builds its endpoint from `URL.host`/`URL.port` and takes the credential from
   the separate `username`/`password` fields, so userinfo was discarded.
   Nothing failed: tor's `SocksPort auto IsolateSOCKSAuth IsolateDestAddr`
   needs no authentication, so the connection was accepted and circuits fell
   back to being keyed by destination alone, while the UI reported each site as
   isolated. **Fixed as PROXY-025 in #605, and #605 must not be reverted** —
   it lands on the direct per-store path, not only the relay path.
4. **The app's own mitigation cancelled the navigations the user makes.**
   `ProxyCoverageEngine` called every post-mount navigation on a per-site
   binding `unprovable` and `onNavigationAction` returned `CANCEL` for it
   (LEAK-010). Built entirely on attempts 90 and 92, so it was blocking
   traffic the store's proxy was already carrying: a proxied site loaded its
   landing page and then refused every link on it. **Fixed** — a configured
   proxy now establishes coverage on both bindings. This is the reason the
   feature looked broken to a user even where WebKit was doing its job.

5. **An unparseable proxy string does not fail: it unproxies the store.**
   `ProxySettings.toProxyConfigurations()` skips every rule whose
   `toProxyConfiguration()` returns nil and the caller assigns the result
   unconditionally. `-[WKWebsiteDataStore setProxyConfigurations:]` treats nil
   *or an empty array* as `clearProxyConfigData()`, which clears
   `m_nwProxyConfigs` for that store's whole network session. One malformed
   rule — and the app only ever sends one — turns "set this site's proxy" into
   "remove this site's proxy". The same function defaults a missing port to 80
   and rewrites a scheme-less `host:port` to `http://`, so a SOCKS endpoint
   typed without a scheme silently becomes a CONNECT proxy. **Fixed in the
   fork:** `toProxyConfigurations()` now returns an optional and yields nil on
   any unusable rule, and both call sites — the process-wide override and the
   per-WebView bind — leave the store's existing proxy alone rather than
   assigning an empty array. The app reached it by re-resolving the pin: the
   `v6.2.0-beta.3-privacy-v8` tag was moved onto the fix, and `pubspec.lock`
   still named the commit it had resolved to before that.

## What the platform actually does

Measured 2026-09-22 on macOS 15.7.3 (24G419) arm64, in a standalone
`WKWebsiteDataStore` + `ProxyConfiguration` + `WKWebView` program with no
Flutter and no fork, and again through the shipped app over the pinned fork:

- A store's proxy binds on **every** navigation, not only the first. Nine
  stores mounted from frame 1 out to fifteen seconds each reached their own
  upstream, on `nonPersistent()` and `WKWebsiteDataStore(forIdentifier:)`
  alike, and so did every second navigation to a different origin.
- Distinct upstreams **and** distinct credentials work per store,
  simultaneously, on SOCKS5 (RFC 1929) and on HTTP CONNECT (Basic, after one
  407).
- There is no "one proxied process at a time" resource and no frame boundary.

Through the app, with containers on:

```
run=local verdict: containers=true frame1=own next-frame=own 50ms=own
  150ms=own 500ms=own 2s=own 5s=own 10s=own 15s=own
```

**Consequence:** the Apple local proxy relay is unnecessary. It exists because
Android has one process-wide `ProxyController` rule and Chromium caches a proxy
credential per `HttpNetworkSession` without partitioning it. Apple has neither
problem, so each store binds its real upstream directly and the relay is a hop
that buys nothing while adding the credential-forwarding step instance 3 was a
defect in. Disabled on Apple behind
`ProxyRouterService.appleRelayEnabled`, which stays for parity testing and is
turned on by exactly one arm, `proxy_apple_relay_parity_test.dart`: two sites
through one relay endpoint, told apart only by the credential each presents,
each asserted to come out of its own upstream. That is Android's attribution
assertion, so the two platforms' routers stay comparable and the kept
implementation cannot rot unnoticed.

## Why 101 attempts read the opposite

**Every proxy arm pointed its destinations at an address of the test machine
itself**, via `nonLoopbackIPv4()`. macOS routes traffic aimed at any address
the host owns over `lo0`, and Apple never proxies a loopback-routed
destination. So the arms read DIRECT whether or not the proxy was bound. The
helper's own doc comment named the rule (`127.0.0.1` is never proxied) and
misjudged its reach: the machine's LAN address is loopback-routed too.

The control, one process, interleaved, only the destination varying:

```
rung0[host-own-IP]=DIRECT  rung1[other-host-same-/24]=own  rung2[off-subnet]=own
rung3[host-own-IP]=DIRECT  rung4[other-host-same-/24]=own  rung5[off-subnet]=own
```

The exclusion is the host's *own* address, not private addressing and not the
local subnet, so adding an interface to the same machine does not escape it.

Withdrawn with it: the "navigation is proxied only in the process's first
frame" claim, the "structural boundary, app side closed" conclusion, the "one
app process at a time can proxy" gap, and the upstream WebKit report drafted
from them, which was never filed and must not be. The attempt-by-attempt
record lives in this file's git history and in PR #603; it is not reproduced
here because every DIRECT reading in it is void.

## How to measure this, now and in future

A proxy arm's destination must be one **this machine does not own**, and the
fixture must be the only thing that can serve it. `syntheticOrigin(i)` returns
`10.99.99.<i+1>`, which has no route off the box; `Socks5Fixture` and
`HttpConnectFixture` answer it themselves rather than relaying, terminating TLS
with `syntheticTls` when the arm is `https://`. A request arriving at a fixture
is then the proof, with no origin-side port attribution and no second machine,
and a bypassed request cannot arrive anywhere by accident.

`test/js/proxy_binding_fixture.test.js` fails any arm that builds a
destination from `nonLoopbackIPv4()`.

## Known open gaps

1. **A moved tag does not reach a locked build.** The fork is pinned by tag,
   and `pubspec.lock` pins the commit that tag resolved to, so moving a tag
   onto a fix leaves every build on the old commit until someone re-resolves
   it. That is how instance 5 read as unfixed here long after it was fixed.
   Nothing compares the two.
2. **Fail-closed is unmeasured.** "A refused proxy must not leak to the origin"
   needs a destination that is both proxyable (so not host-owned) and
   observable when reached directly (so not synthetic). No single machine can
   be both; it needs a second host, which is why the origin is moving to a CI
   service container.
3. **No general guard on the seam.** The plugin's settings parser fails open by
   construction and nothing compares the map Dart sends against the properties
   the native side set. `getRealSettings` could answer that for a live WebView.
4. **Reach is wider than the proxy.** The same parser carries the container id,
   the UA, the media gates and every other per-site field. Only the proxy has
   an effect-level test.
5. **An effect-level test can be unfalsifiable and look green — or look red.**
   Both failure modes have now happened here: assertions satisfied by any
   broken load, and ninety-odd attempts of DIRECT that the instrument would
   have produced regardless. The rule that survives is that an effect-level
   assertion needs a control which fails when the instrument is broken, **in
   the same process as the claim**. Nothing enforces the class.
6. **The readback is not evidence.** `WKWebsiteDataStore`'s
   `proxyConfigurations` getter is a UI-process cache that never asks the
   network process, so `configured=1` proves only that the UI process
   remembers what was assigned.
