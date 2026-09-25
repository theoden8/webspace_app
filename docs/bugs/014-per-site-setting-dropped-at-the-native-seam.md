# BUG-014 — A per-site setting the Dart side sends and the native side drops

Status: **open, narrowed.** The per-site proxy on Apple works: measured on real
hardware, every store binds its own upstream and its own credential, at any
frame and on later navigations. The long investigation that said otherwise
was reading a broken instrument; what it produced worth keeping is the
cautions below, not its route. Two instances of the seam's real defect are
fixed, a third was fixed in the fork, and the seam now has a general guard:
`settings_seam_test.dart` compares every per-site field Dart sends against
what the engine actually holds -- the comparison nothing was making -- on
every platform whose engine answers `getSettings()`, not just the one the
investigation started on. A fourth instance of the same shape is open on
Android, where an empty rule list unproxies the whole process (instance 6).

**Spec:** [ip-leakage](../../openspec/specs/ip-leakage/spec.md) LEAK-003,
[proxy](../../openspec/specs/proxy/spec.md) PROXY-011,
[tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md) TOR-018,
[proxy](../../openspec/specs/proxy/spec.md) PROXY-028 (instance 8)
**Tests:** one arm per guarantee, each reading its verdict off a destination
only a proxy can reach: `proxy_binding` (the binding survives navigation and
is not shared between sites), `proxy_frame_ladder` (it holds at any distance
from the first frame), `proxy_http_connect` and `proxy_connect_https`
(delivery over CONNECT, plaintext and TLS), `proxy_simultaneous` (Linux, per
container), `proxy_apple_relay_parity` (the relay Apple keeps but does not
take), `proxy_fail_closed` (Linux, caution 13), `proxy_rebind` (a proxy
change reaches a host the site already had a connection to, instance 8).
`test/js/proxy_binding_fixture.test.js` gates their shape.
Two more sit beside them: `proxy_malformed_rule` (Apple, same instrument --
an unusable rule must not clear the store the last one bound) and
`settings_seam` (iOS, macOS, Android, Linux -- no destination at all, it
compares every per-site field against what the engine holds).
`test/js/proxy_override_rules_nonempty.test.js` gates the Android shape of
the same defect.

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

6. **An empty proxy rule list unproxies every WebView in the process
   (Android).** `ProxyManager.setProxyOverride` loops `addProxyRule` over the
   rules it was handed and installs the result unconditionally. A rule
   Chromium cannot parse is the loud case: `AwProxyController.setProxyOverride`
   throws `IllegalArgumentException` carrying the native error before anything
   is installed, so the previous override stands and the throw crosses the
   channel as a `PlatformException` (Flutter's `MethodChannel` catches a
   `RuntimeException` from a handler and replies with an error envelope). An
   EMPTY list is the silent one: a zero-length array is not an error, the
   native call installs an override carrying no rules at all, the listener
   reports success, and every WebView in the process goes direct while the
   Dart side logs "Applied proxy override". That is instance 5's shape
   (`setProxyConfigurations:` routing `[]` to `clearProxyConfigData`) arriving
   through a different door, on the platform where the rule is process-wide
   rather than per-store, so it unproxies every site at once rather than one.
   **Not reachable from the app today** -- caution 12 again: all three call
   sites build exactly one rule from a `host:port` each validates first.
   Gated by `test/js/proxy_override_rules_nonempty.test.js`, which fails a
   call site that computes its rule list instead of naming one. The fork-side
   fix is the symmetric one: refuse the override when the list comes out
   empty, the way the Apple call sites now leave the store's proxy alone.

7. **The Tor exit-country pin was accepted and never in force (iOS, macOS).**
   Reported 2026-09-23: a site pinned to Brazil kept reporting a Dutch exit.
   `SETCONF ExitNodes={br} StrictNodes=1` answered 250 OK, the engine marked
   the pin applied, and tor logged `Failed to open GEOIP file` (a path on the
   machine that built `tor.xcframework`) followed by "0% of exit bw". tor
   resolves `{cc}` against its IPv4 GeoIP table and the app never gave it one
   (`pod 'Tor'` resolves to `Tor/CTor`, which ships none), so the pin named no
   relay at all. The page still loaded, from the Netherlands: a change to
   `ExitNodes` only stops tor attaching *new* streams to older circuits, and
   the recreated webview reused a pooled connection opened before the pin.
   Two failures, each hiding the other: without the pooled connection the
   site would have hung, which reads as a dead country, not a missing table.
   **Fixed 2026-09-23** in TOR-014: the table is downloaded on the device
   through Tor, never bundled (LICENSE-002 rules out `Tor/GeoIP`, whose data
   is CC BY-SA 4.0); the plugin loads it with `SETCONF GeoIPFile`, confirms
   `ip-to-country/ipv4-available`, and only then sets `ExitNodes`; every
   exit-capable circuit is closed after a pin change; and the engine holds
   `up` back until the pin lands. Gated by `test/tor_engine_test.dart`
   (TOR-014 GeoIP group) and `test/js/tor_geoip_not_bundled.test.js`.
   The activation hang the same field report ended in, a clear awaited on a
   control socket that no longer answered, is BUG-018.
   **Partial, found 2026-09-24** (#619) by the first run of the pin against
   the real network, `integration_test/tor_test.dart` on the macOS tier. The
   table came from the onion service (9,725,448 bytes, pin in force 11-12 s
   after it was set), and a stream held open under one pin ended when the
   next landed, but the exit did not follow the pin: under `{us}` the check
   left from 185.220.101.20 (DE), and under `{de}` from 5.255.119.254, which
   tor's own table and the relay directory both put in the Netherlands, with
   `ExitNodes={de}` and `StrictNodes=1` in force. Closing the circuits
   covered `GENERAL` ones and not conflux. Closing a conflux leg makes tor
   launch a recovery leg with the exit its set already uses
   (`unlinked_circuit_closed`, `get_exit_for_nonce`), and a stream takes any
   linked set whose exit is not *excluded* (`conflux_get_circ_for_conn`,
   `circuit_is_acceptable`), which no pre-pin exit is. **Second fix
   2026-09-24**: the pin sets `ConfluxEnabled 0` in the same SETCONF as
   `ExitNodes`, before closing anything, so no leg can link and no stream
   rides a set built before the pin; clearing it restores `auto`. Gated by
   `test/js/tor_exit_pin_conflux.test.js` and the XCTest
   `testExitPinTurnsConfluxOffAndClearingRestoresIt`; measured by the same
   integration scenario, which now reads tor's circuit and stream tables
   over a control connection of its own. Measured the same day with conflux
   off: `{de}` left from 185.220.101.4 and `{us}` from 204.8.96.108, which
   tor places in Germany and the United States, and the circuit table after
   each pin held no conflux leg, only the onion-service circuits of the
   table download.
   **Third finding 2026-09-25** (#627), from a device: with the pin finally
   in force, Brazil loaded nothing while the runtime said `up`. Brazil had 32
   relays and no running exit, so under `{br}` with `StrictNodes 1` tor found
   "0% of exit bw", stopped treating its directory as usable and built no
   circuit at all; each page timed out a minute later. The conflux leak had
   hidden this by leaving from the Netherlands. Reproduced on the macOS tier
   by pinning `{aq}`: the consensus listed 3176 exits and none in AQ, and the
   pin answered `up` at once. **Fixed** (e43227d): the plugin counts the
   consensus relays with the Exit flag and without BadExit that tor's table
   places in the pinned country, and with none answers `exit_country_empty`,
   which the engine reports as `exitPolicy` with the pin kept in force.
   **Partial:** the count is taken when the pin is applied. A country whose
   last exit leaves the consensus later is not re-checked, and reads as
   before, a hang until a Retry.

8. **A proxy change reached the live session and not the connections it
   already held (iOS, macOS).** Reported 2026-09-25: a site that loaded
   direct and was then moved to Tor in its settings still showed the
   device's own address, while its rebuilt WebView reported the proxy bound.
   After a restart it showed that address once more, from the page snapshot
   saved before the restart, and then the Tor exit. The fork caches one
   `WKWebsiteDataStore` per container for the life of the process, and the
   store keeps one network session. WebKit hands a SOCKS change to that live
   session in place (`NetworkSessionCocoa::setProxyConfigData` adds it to the
   session's `nw_context`; only a proxy that needs HTTP protocols rebuilds
   the session), so the next connection honours it and a pooled one does not.
   Reproduced 2026-09-25 on the macOS tier before any fix (run 36112534629):
   `proxy_rebind_test.dart` moved a site from one keep-alive SOCKS fixture to
   another and read `same-host=OLD fresh-host=new`, the same host riding
   tunnel 0 of the old proxy; `tor_test.dart` scenario 6 loaded Cloudflare's
   trace direct, moved the site to Tor, and was seen from the runner's
   address both times. **Fixed 2026-09-25** (#627, fork f40e2a7):
   `ContainerController.resetNetworkSession` drops the fork's cached store and
   waits for WebKit to destroy it, so the next store for the container starts
   a session bound to its first WebView's proxy before any connection opens;
   cookies and storage are on disk under the identifier and carry over. The
   app records which route each container's session was opened on
   (`ContainerSessionRoutes`), and `createWebView` builds nothing on a
   container whose session carries another route until the reset lands,
   retrying while something still holds the store. Gated by
   `test/container_session_routes_test.dart` and the two integration arms.
   **Partial:** Linux binds the proxy on a cached `WebKitNetworkSession` the
   same way and is not reset; whether its pooled connections outlive a
   `webkit_network_session_set_proxy_settings` is unmeasured. Android's
   override is process-wide and was not examined. A popup or nested browser
   still bound to the container keeps the old session alive, and the site
   then waits behind a spinner rather than loading.

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

11. **Not every readback is worthless.** Caution 5 is about
    `WKWebsiteDataStore.proxyConfigurations`, a UI-process cache. The plugin's
    `getSettings()` is a different call: it returns
    `settings.getRealSettings(obj: self)`, which starts from the parsed
    settings object and then overwrites specific keys by reading the live
    `WKWebView` -- `userAgent` from `webView.customUserAgent`,
    `javaScriptEnabled` from `configuration.defaultWebpagePreferences`. A
    field in that overwrite set is read off the real view; a field outside it
    reflects the parser only, which is still the level caution 7 is about.
    Distinguish the two before calling a readback evidence, in either
    direction.

12. **A guard in front of a guard hides which one is holding.** The app cannot
    emit a malformed proxy rule at all: `splitProxyAddress` rejects the address
    and `userProxyToInappProxy` returns null, which trips the
    `proxyUnavailable` fail-closed branch. So instance 5's fork fix is a second
    line of defence that the app's own path never reaches, and an arm that
    drives it through `WebViewConfig` would pass whether or not the fork was
    fixed. `proxy_malformed_rule_test.dart` builds `inapp.ProxySettings` by
    hand for that reason.

13. **Fail-closed cannot be measured on one machine.** It needs a destination
    both proxyable (so not host-owned) and reachable directly (so a leak is
    visible). The Linux tier gets one from a CI service container on its own
    bridge network; Apple has no equivalent, because service containers need
    Docker and macOS runners have none.

14. **The readback does not see the same fields on every platform, and one of
    them cannot see the field this bug is named after.** `getRealSettings` is
    four implementations:
    * **Android** starts from `toMap()`, every parsed field, then overwrites
      `userAgent`, `javaScriptEnabled` and friends from the live
      `WebSettings`.
    * **macOS** builds `toMap()` with `Mirror(reflecting:)`, so Swift-only
      properties are in it, `proxySettings` included.
    * **iOS** builds `toMap()` with `class_copyPropertyList`: Objective-C
      properties only. `proxySettings` is typed `[String: Any?]?`, which has
      no ObjC representation, so it is *invisible* in an iOS readback even
      when it was parsed and applied. The property the parser could not see is
      the property the readback cannot see, for the same reason.
    * **Linux** does not start from `toMap()` at all. It returns eight keys
      read off `WebKitSettings`, so every other field is absent rather than
      wrong.
    Comparing a field the local readback cannot see reports a loss that is not
    one. `settings_seam_test.dart` carries the platforms per field and prints
    what it skipped, with the reason.

15. **The same symptom has a different cause on each side of the port, so a
    guard written against one mechanism misses the other.** Apple's
    `ISettings.parse` is reflective and fails open: a property the ObjC
    runtime cannot see is skipped. Android's `InAppWebViewSettings.java`
    parses an explicit `switch`, so nothing is invisible there -- but a field
    no arm names is dropped just as silently, and that is the likelier Android
    defect: a field nobody wired rather than one the runtime could not see.
    Same map, same channel, same symptom. The comparison -- what Dart sent
    against what the engine holds -- is the only thing that catches both,
    which is why it runs on every platform whose engine answers
    `getSettings()` rather than on Apple alone.

16. **tor's 250 OK is not the setting in force.** tor accepts `ExitNodes`
    naming a country it cannot resolve, and answers 250 OK to a change that
    leaves every open stream on its old circuit. The acknowledgement says the
    option was stored; what it does to traffic has to be asked separately
    (`ip-to-country/ipv4-available`) or forced (closing the circuits).
17. **Closing a circuit can rebuild it.** A conflux set treats a closed leg
    as damage and relaunches it with the set's own exit, chosen before
    whatever change prompted the close. Closing every exit circuit after a
    pin therefore regrew the pre-pin sets, and the circuit table right after
    the pin showed only fresh `CONFLUX_UNLINKED` legs. Whether an exit
    follows a setting is answered by the traffic, not by what was closed.

18. **A bound proxy is not a fresh route.** The readback, the engine's
    settings and every new connection agreed the site was on its new proxy,
    and the request that mattered went out on a connection opened before the
    change. A test of a proxy *change* has to ask the same host again, over a
    fixture that keeps its connections alive; a fixture that closes each one
    cannot see this.

## Open

1. **Fail-closed on Apple: closed as not measurable in CI.** The guarantee is
   real and it is asserted, on Linux, by `proxy_fail_closed_test.dart` against
   a CI service container on the job's bridge network. Apple has no equivalent
   and this is not a gap that waits on effort: the assertion needs a
   destination both proxyable (so not an address the machine owns, caution 1)
   and reachable directly (so a leak is visible), and one machine cannot be
   both. Service containers need Docker, which macOS runners do not have; a
   `feth` pair does not help because both ends belong to the same host
   (caution 1); a second job is on its own network; and an external host is
   what the egress guard exists to forbid. A nested VM on the runner is the
   only remaining shape and it buys one platform's copy of a guarantee already
   held on another, which is not worth a virtualization dependency in the
   Apple tier. **The platform question behind it is answered** -- the binding
   itself is measured on Apple by the arms above -- so what is unmeasured is
   the refusal path, on one platform, for a mechanism shown to work. Revisit
   only if macOS runners gain containers.

2. **Instance 5 on Apple: closed.** `proxy_malformed_rule_test.dart` binds a
   store with a well-formed rule, re-mounts the same container with a rule the
   fork cannot parse, and asserts the store's navigation still reaches the
   fixture. Its control runs first and is asserted: a well-formed rule must
   reach the fixture, or nothing the arm says afterwards is evidence. See
   caution 12 for why it builds the rule by hand.

   **The same question on Android: answered, and it splits in two.** A rule
   Chromium cannot parse does not degrade there -- it throws before anything
   is installed, so the previous override stands. An empty rule list does
   degrade, silently and process-wide, which is instance 6. The app cannot
   produce one today and `test/js/proxy_override_rules_nonempty.test.js` is
   what keeps that true; the fork-side refusal is still owed.

3. **The general guard on the seam: closed, on every platform that can
   answer.** `settings_seam_test.dart` sends each per-site field with a value
   that is not the engine's default, asks the engine what it holds through
   `getSettings()`, and fails naming any that did not survive -- the
   comparison nothing was making, which is what let instance 1 ship. Its
   control is effect-level and runs before the comparison is read: the page's
   own `navigator.userAgent` must report the string the test sent, because an
   engine that echoed the map it was handed would satisfy a readback alone
   (caution 2).

   It is not Apple-only, because the defect is not (caution 15): it runs on
   iOS, macOS, Android and Linux, and each field names the platforms where
   comparing it means something (caution 14). `userAgent` and
   `javaScriptEnabled` are compared everywhere and read off the live view;
   `preferredContentMode` everywhere but Linux; `containerId` and `incognito`
   on the three that report them, container binding permitting;
   `thirdPartyCookiesEnabled` on Android, the only side that has the field;
   `proxySettings` on macOS, the only readback that can see it. A field that
   skips itself is printed with the reason, and the run fails if nothing was
   compared or if nothing compared was read off the live view -- a gate that
   can only skip is not a gate (caution 8).

   Where it runs: the macOS tier's integration loop, the Linux loop (WPE
   answers with the live `userAgent` and `javaScriptEnabled`, so it asserts
   rather than skipping), and the emulator job through
   `scripts/run_android_settings_seam_test.sh`, which prints the System
   WebView version because the `containerId` half depends on that image
   reporting MULTI_PROFILE.

   **Extend it when you add a per-site field** -- that is the point of it, and
   a field not in its table is a field nothing compares.

4. **Instance 7 against the real network: measured on the macOS tier,
   not yet on an iOS device.** `integration_test/tor_test.dart` pins `{de}`
   then `{us}` on the real tor and places the address check.torproject.org
   sees with the table the pin downloaded. Measured 2026-09-24: the onion
   download works and takes 11-18 s, a connection kept open under one pin
   ends when the next lands, and with conflux off the exit follows the pin
   (`{de}` from Germany, `{us}` from the United States, by the web's view and
   by tor's). The macOS tier runs the same plugin source as iOS, but not the
   iOS suspension and resume that BUG-018 came from, so a device run is
   still the last word for the field report.
   The device run of 2026-09-25 took 12 s for the table download, and found
   the exitless-country gap and instance 8 above; both are reproduced and
   fixed on the macOS tier. Tor after a background launch and suspension
   is still unmeasured by any tier.
