# BUG-014 — A per-site setting the Dart side sends and the native side drops

Status: **open, narrowed.** The per-site proxy on Apple works: measured on real
hardware, every store binds its own upstream and its own credential, at any
frame and on later navigations. The long investigation that said otherwise
was reading a broken instrument; what it produced worth keeping is the
cautions below, not its route. Two instances of the seam's real defect are
fixed, a third was fixed in the fork, and the seam still has no general
guard.

**Spec:** [ip-leakage](../../openspec/specs/ip-leakage/spec.md) LEAK-003,
[proxy](../../openspec/specs/proxy/spec.md) PROXY-011,
[tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md) TOR-018
**Tests:** one arm per guarantee, each reading its verdict off a destination
only a proxy can reach: `proxy_binding` (the binding survives navigation and
is not shared between sites), `proxy_frame_ladder` (it holds at any distance
from the first frame), `proxy_http_connect` and `proxy_connect_https`
(delivery over CONNECT, plaintext and TLS), `proxy_simultaneous` (Linux, per
container), `proxy_apple_relay_parity` (the relay Apple keeps but does not
take), `proxy_fail_closed` (Linux, caution 11).
`test/js/proxy_binding_fixture.test.js` gates their shape.

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
   (LEAK-010). Built on a measurement that could not have read
   anything else, so it was blocking
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

## Cautions

Not a record of what was tried. A record of what bit, so it bites once.

1. **A destination this machine owns is never proxied.** macOS routes traffic
   aimed at any address the host holds over `lo0`, and Apple never proxies a
   loopback-routed destination. That is broader than `127.0.0.1`: the
   machine's own LAN address is just as unproxyable, which is what
   `nonLoopbackIPv4()` returned and what every arm pointed at. Measured in one
   process, interleaved, only the destination varying:

   ```
   rung0[host-own-IP]=DIRECT  rung1[other-host-same-/24]=own  rung2[off-subnet]=own
   ```

   The exclusion is the host's *own* address, not private addressing and not
   the local subnet. Adding an interface does not escape it: a `feth` pair
   belongs to the same host at both ends. Use `syntheticOrigin()`.

2. **An effect-level test can be unfalsifiable and look red.** The famous
   shape is green-by-vacuity, and this file has that too (assertions any
   broken load satisfies). The one that cost most was the mirror: readings of
   DIRECT the instrument would have produced whether or not the feature
   worked. A control has to be in the same process as the claim and has to
   fail when the instrument breaks, not merely differ from the claim.

3. **A mitigation built on a wrong diagnosis becomes the bug.** The coverage
   gate cancelled every post-mount navigation on a proxied site to avoid a
   leak that was not happening, so the feature refused the traffic its own
   proxy was carrying. A fail-closed guard is only as good as the measurement
   under it.

4. **A moved tag does not reach a locked build.** The fork is pinned by tag and
   `pubspec.lock` pins the commit that tag resolved to, so moving a tag onto a
   fix leaves every build on the old commit. A defect can read as open long
   after it is fixed. Re-resolve, do not assume.

5. **The readback is not evidence.** `WKWebsiteDataStore.proxyConfigurations`
   is a UI-process cache that never asks the network process, so `configured=1`
   proves only that the UI process remembers what was assigned.

6. **An empty array is a clear, not a no-op.** Assigning `[]` to
   `proxyConfigurations` routes to `clearProxyConfigData()` and strips the
   proxy off the live session. An embedder that filters unparseable rules out
   of its array turns "set this site's proxy" into "remove it".

7. **A parser that fails open is silent by construction.** `ISettings.parse`
   sets values reflectively behind `responds(to:)`; a property the ObjC runtime
   cannot see is skipped with no error. A Swift-only type is invisible. The
   Dart side logs what it sent, the native side acts on what it parsed, and
   nothing compares them.

8. **A skipped test is counted as a run.** A gate that can only skip is not a
   gate: a missing `openssl`, an unawaited `PlatformInfo.initialize()`, a
   platform check that answers false first, or an emulator image whose System
   WebView lacks `MULTI_PROFILE` all produce a green tick over nothing. Print
   what the gate depended on, so a reader can tell a pass from an absence.

9. **Nothing guards the gates.** Removing a structural gate in the same commit
   as the code it guarded is silent by definition, and it happened here: two
   attempts were then written from readings the instrument could not have
   produced.

10. **A comment outlives the thing it describes.** The Android router tier's
    note described an image the workflow had stopped pinning, and reading it
    instead of the workflow produced a wrong conclusion about CI coverage.

11. **Fail-closed cannot be measured on one machine.** It needs a destination
    both proxyable (so not host-owned) and reachable directly (so a leak is
    visible). The Linux tier gets one from a CI service container on its own
    bridge network; Apple has no equivalent, because service containers need
    Docker and macOS runners have none.

## Open

1. **Instance 5 on Apple.** Fixed in the fork and in the pin. No arm covers it:
   nothing asserts that a malformed rule leaves a store's existing proxy
   alone rather than clearing it.
2. **Fail-closed on Apple.** Caution 11. `proxy_fail_closed_test.dart` asserts
   it on Linux and skips elsewhere with its reason.
3. **No general guard on the seam.** Caution 7 is the root mechanism and only
   the proxy has an effect-level test; the same parser carries the container
   id, the UA, the media gates and every other per-site field.
   `getRealSettings` could answer it for a live WebView.
