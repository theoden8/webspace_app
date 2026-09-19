# BUG-014 — A per-site setting the Dart side sends and the native side drops

Status: open (one instance fixed, one class-level gate; the seam has no general guard)

**Spec:** [ip-leakage](../../openspec/specs/ip-leakage/spec.md) LEAK-003,
[proxy](../../openspec/specs/proxy/spec.md) PROXY-011,
[tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md) TOR-018
**Tests:** `integration_test/proxy_binding_test.dart` (the origin's own view of
whether a proxied load arrived), `test/js/tor_bootstrap_observability.test.js`
(structural, for the Tor half).

## Symptom

A per-site setting is configured, the app reports it as applied, every Dart-side
test agrees, and the behaviour the user asked for does not happen. The setting
crossed the platform channel and was discarded on the far side without a word.

Instances so far: the per-site proxy was never bound to the WebView on iOS or
macOS (a site pinned to Tor loaded over the device IP), and tor's bootstrap
phase was read off the control event and dropped before it reached Dart (the
interstitial showed a bare percentage).

## Root mechanism (the invariant behind every instance)

**Nothing on either side of the channel fails when a field goes missing.** The
Dart side logs what it *sent*; the native side acts on what it *parsed*; no
assertion compares the two, and every tier the repo runs is on one side of it:

- `ISettings.parse` in the plugin sets values reflectively, guarded by
  `responds(to:)`. A property the Objective-C runtime cannot see is skipped
  silently. `proxySettings` was typed `[String: Any?]?` — a Swift type with no
  ObjC representation — so it was never exposed, never set, and never bound.
  The file's own comment already warned about the same class for nullable
  primitives (`alpha`), which are handled explicitly for exactly this reason.
- On the Tor side the phase arrived in a `STATUS_CLIENT` event whose `TAG` and
  `SUMMARY` the plugin never read.

A Dart test asserts what Dart sends. A structural gate asserts what the sources
contain. Only something that observes the *effect* — the origin server seeing a
request, tor's own log carrying a phase — can catch a field that vanishes in
between.

## Fix attempts (chronological)

### Attempt 1 — The phase dropped at the Tor seam
**Date:** 2026-09-15 · **Commit:** 923f928 · **Files:**
`ios/Runner/TorControllerPlugin.swift`, `lib/services/tor_service.dart`
**What it did:** read `TAG` and `SUMMARY` off the BOOTSTRAP status event, publish
them in the status payload, and decode them under the same keys in Dart.
**Why:** the interstitial could only show a percentage, so a user waiting on Tor
could not tell bootstrapping from stuck.
**Why it was partial:** it fixed one field on one channel. The seam itself stayed
unguarded, and the proxy instance below was already shipping.

### Attempt 2 — The per-site proxy was never bound on iOS or macOS
**Date:** 2026-09-15 · **Commit:** fork `d128d89`, app re-pin · **Files:**
`flutter_inappwebview_{ios,macos}/.../InAppWebViewSettings.swift` (fork),
`pubspec.yaml`, `integration_test/proxy_binding_test.dart`
**What it did:** parse `proxySettings` explicitly in the `parse` override, beside
the nullable primitives that need the same treatment, instead of leaving it to
the reflective path that cannot see it. Added an integration scenario that
asserts the origin never receives a load from a site whose proxy is refused.
**Why:** reported from a device: two sites on the same IP-reporting service, one
pinned to Tor with the runtime up, both showing the device's own address. The
Dart log said `proxySettings=true` on the very webview that loaded direct.
**Why it was partial:** it fixes the one field. Every other field on
`InAppWebViewSettings` still rides the same reflective parser, and the new test
observes the proxy only — a second setting dropped the same way is still silent.

### Attempt 3 — The gate ran, and the proxied request still went direct
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`,
`.github/workflows/build-and-test.yml`
**What it did:** the macOS tier finally ran `proxy_binding_test.dart` end to end and
it failed on the half that matters — the control load reached the fixture origin, and
so did the load from a site whose SOCKS5 proxy pointed at a closed port:
`Expected: not contains '/proxied' / Actual: ['/proxied']`, with
`proxySupported=true`. So attempt 2's parse fix is not sufficient on its own.
Reading the test back turned up a flaw that is also a candidate mechanism: both
scenarios used one `siteId`, so the second webview was handed the **cached container
data store the first had already used**, and the proxy was assigned to a store that
was already in service. The scenarios now use separate sites, and a third one
reproduces the reuse deliberately — an unproxied load, then a proxied one on the same
site — which is the shape of the user's "sometimes I have to restart the app for the
Tor proxy to start working".
**Why:** a proxy assigned to a `WKWebsiteDataStore` that has already served a load may
not apply to it; the store is cached per container for the life of the process, so if
that is what happens, the only proxy a site ever gets is the one its first webview was
built with. Apple's page for `proxyConfigurations` is not in the public documentation
archive, so this is a hypothesis the next run decides, not a cited fact.
**Why it was partial:** it splits the two mechanisms so the next run says which one is
real. It fixes neither.


### Attempt 4 — The gate could never have caught it: Apple does not proxy loopback
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`,
`integration_test/socks5_fixture.dart`, `test/js/proxy_binding_fixture.test.js`
**What it did:** attempt 3's two scenarios disagreed — the fresh-site one failed and
the rebind one passed — which is backwards for the cached-store hypothesis. Reading
the fixture rather than the product explains both. The origin was on `127.0.0.1`,
and Apple's networking stack never sends a loopback destination through a proxy:
`localhost`, `127.0.0.1` and `::1` are direct whatever `ProxyConfiguration` says, and
`kCFStreamPropertyProxyLocalBypass` does not change it. So the fresh-site scenario
was asserting something that cannot hold, and the rebind scenario passed for a second
reason: pumping the same widget position again *updates* the existing `InAppWebView`
element, keeping the platform view it already had, so the second load was never issued
and "the origin was not reached" held for free. Both scenarios were unfalsifiable.
The fixture now serves the origin on a non-loopback interface address, every mount
gets its own subtree key, and a real SOCKS5 server (`socks5_fixture.dart`) records the
CONNECT it is asked for — so the assertions are positive ("the proxy was used") rather
than negative ("the load did not arrive"), which every broken load satisfies.
**Why:** a negative assertion over a load that cannot succeed proves nothing, and both
ways this file has been wrong so far broke the load. A recorded CONNECT to the origin
cannot be produced by a dropped binding.
**Why it was partial:** it fixes the instrument, not the product. Whether the per-site
proxy is bound on a fresh site, on a re-used container store, or at all, is what the
next macOS tier says — attempt 3's verdict tells us nothing, because neither of its
scenarios was measuring what it claimed.


### Attempt 5 — With a gate that can fail, no proxy is applied at all
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** the repaired gate (attempt 4) ran, and its verdict is unambiguous:
**1 passed, 3 failed**. The control — an unproxied site on the routable fixture
origin — reached the origin, so the harness works. All three proxied scenarios
failed, and each fails in the direction that means "no proxy":

  * a fresh site pointed at a *live* SOCKS5 server: the server was never asked
    for anything (`rebound load (must arrive at the proxy) -> timeout`);
  * a fresh site pointed at a *closed* port: the load reached the origin anyway,
    which a bound proxy with `allowFailover` at its default cannot do;
  * the rebind: `unproxied first load -> ok`, then the proxied one never
    reached the proxy either.

So it is not the cached container store (attempt 3's hypothesis), and it is not
loopback (attempt 4's). The per-site proxy is not applied on a fresh webview at
all, and `proxyUnavailable` proves the Dart side sent one: had `inappProxy` been
null, the fail-closed branch would have rendered nothing and the *refused*
scenario would have passed by never loading. It loaded.

Ruled out by reading the pinned fork rather than guessing: the macOS plugin does
carry the same `preWKWebViewConfiguration` proxy block as iOS (it is not an
iOS-only feature), and `InAppWebViewSettings.toMap` does serialise
`proxySettings` (line 3071 of the generated file), so the field is on the wire.
That leaves the far side: `ISettings.parse` not taking the patched branch, or
`ProxySettings.fromMap` returning nil, or the assignment not reaching the store
the WebView ends up with.

A fifth scenario now asks the engine directly — `getSettings()` on the native
controller, asserting `proxySettings.proxyRules` is non-empty. That splits the
seam the other four can only see the far side of: a null there means the field
never crossed, non-null means it crossed and was not applied. The two are
different bugs and the load-level assertions cannot tell them apart.
**Why:** four scenarios agreeing on "no proxy" is a mechanism, but not a
location. One `getSettings()` call is worth another cycle of hypotheses.
**Why it was partial:** it still fixes nothing. It converts the next run from
"which of three guesses" into a yes/no on one of them.


### Attempt 6 — The field crosses; the store it lands on has already been used
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** the seam scenario answered the question attempt 5 posed. Five tests,
**two passed** — the control and the seam check — and the three load-level proxied
scenarios failed. So `InAppWebViewSettings.proxySettings` *is* set on the native
object: the patched `parse` works, and `getSettings()` reflects the Swift property
through `Mirror` (`ISettings.toMap`), which is exactly what it reads back. The field
crosses the channel. Nothing applies it.

Reading the fork's creation path narrows where "nothing applies it" can be.
`FlutterWebViewController` parses the settings and *then* calls
`preWKWebViewConfiguration(settings:)`, so the proxy is present there; that function
assigns `configuration.websiteDataStore.proxyConfigurations` and nothing later in it
reassigns the store (the other `websiteDataStore` writes are in `setSettings`, the
runtime-update path, which does not run at creation).

Which leaves the store itself. With no container id — and this test never initialises
`ContainerNative`, so `siteOwnsContainerProfile` yields none — every WebView gets
`WKWebsiteDataStore.default()`, a process singleton. Apple's `proxyConfigurations`
applies to a store *before* it is used for network loads. The control scenario runs
first and loads through that store; every proxied scenario afterwards assigns a proxy
to a store that has already served traffic, and is ignored. That single mechanism
fits all five results, including the two that pass.

It is also the shape of the user's report — a site that loads once without a proxy
keeps loading without one until the app restarts — and it revives attempt 3's
hypothesis, which attempt 4 appeared to refute only because the scenario testing it
was vacuous.

A sixth scenario now runs **first in the file**, proxied, before anything has touched
the default store. If it passes while the identical fresh-site scenario later fails,
the difference is not the site and not the proxy: it is that the store was clean.
That is a decisive experiment and it needs no fork change.
**Why:** three hypotheses have now been wrong because they were argued rather than
measured. This one is measured by ordering alone.
**Why it was partial:** it still fixes nothing, and if it is right the fix is
fork-side and awkward: the proxy has to be bound when the container's
`WKWebsiteDataStore` is created, not when a WebView is built on one, which means
`ContainerManager`'s cache has to account for the proxy rather than only the
container id.


### Attempt 7 — Confirmed: the store has to be untouched
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** the ordered experiment from attempt 6 answered it. Six tests, **three
passed**, and only one assignment of passes is consistent with that count: the
first-in-process scenario passed, the control passed, the seam check passed, and the
three later proxied scenarios failed. (The alternative — the proxy sticking to the
default store and poisoning the control — works out to four passes and two failures,
not three and three.)

So `WKWebsiteDataStore.proxyConfigurations` **is** honoured, on a store that has not
yet served a network load, and is silently ignored on one that has. The first WebView
in the process went through the fixture SOCKS5 server; an identical WebView later in
the same process, with the same proxy on a fresh `siteId`, went direct. Nothing about
the site or the proxy differs between them. Only the store's history does.

That also explains the report this file exists for. A site that loads once without a
proxy keeps loading without one, because the proxy is assigned to a data store that
is already in service, and only relaunching the app gives it a clean one.

Two changes follow. The fixture now resolves `ContainerNative.isSupported()` in
`setUpAll`, as the app does at startup: without it every WebView here shared
`WKWebsiteDataStore.default()`, a process singleton, so the file was measuring a store
shape the app never uses — in the app each site has a container store of its own. And
each scenario records whether it saw the proxy, printed as one `verdict:` line from
`tearDownAll`, because the tier re-prints only a failing file's last 60 lines and
twice now the deciding scenario was further back than that.
**Why:** three hypotheses were argued and wrong. This one was decided by ordering, and
the count admits one reading.
**Why it was partial:** it identifies the mechanism and fixes the instrument, not the
product. With containers resolved, a fresh site should get a clean store and bind
correctly; a site whose WebView is rebuilt with a different proxy still meets a cached
store that is already in service. That case is the user's "restart the app" symptom
and its fix is fork-side, in `ContainerManager.getOrCreateDataStore` — bind the proxy
where the store is created, and evict the `sharedStores` entry when the proxy differs
from the one it was created with.


### Attempt 8 — Bind the proxy where the store is made
**Date:** 2026-09-16 · **Files:** fork `theoden8/flutter_inappwebview` @ `eecf62e`
(`ContainerManager.swift` and `InAppWebView.swift`, both iOS and macOS),
`pubspec.yaml`, `openspec/specs/ip-leakage/spec.md`
**What it did:** acted on attempt 7's confirmed mechanism.
`ContainerManager.getOrCreateDataStore` now takes the `ProxySettings` and applies
`proxyConfigurations` where it constructs the store, and records which proxy each
cached store was built with; a request for a different one gets a new store instead of
the cached one. `preWKWebViewConfiguration` passes the proxy in rather than assigning
it to whatever store it got back. `WKWebsiteDataStore(forIdentifier:)` returns a new
wrapper over the same on-disk data, so a rebuilt store keeps the container's cookies
and storage, and WebViews already running keep the wrapper — and the proxy — they were
built with.
**Why:** a store only honours `proxyConfigurations` before it has served a load, and
the container's store is cached for the life of the process. Assigning at WebView
construction could therefore only ever bind the first WebView in each container. This
is the "restart the app" half of the report.
**Why it was partial:** it fixes the container path, which is every proxied site in the
app (containers and `proxyConfigurations` share the same iOS 17 / macOS 14 floor).
A WebView with no container still gets `WKWebsiteDataStore.default()`, a process
singleton that cannot be rebuilt — there the first load in the process wins and nothing
can change it afterwards. The app does not take that path for a proxied site, but
nothing prevents it either. And the fix is unverified until the tier runs it: the
`verdict:` line added in attempt 7 is what will say whether `rebind` moved from
`DIRECT` to `proxied`.


### Attempt 9 — Only the first WebView in the process is ever proxied
**Date:** 2026-09-16 · **Files:** fork @ `45f01cd`, `pubspec.yaml`,
`integration_test/proxy_binding_test.dart`, `integration_test/socks5_fixture.dart`
**What it did:** the `verdict:` line from attempt 7 reported for the first time, and it
is not what attempt 8 fixed:

```
verdict: first-in-process=proxied, fresh-site=DIRECT, refused=DIRECT, rebind=DIRECT
```

Attempt 8's store rebuild is in (the fork compiles and ships; the Apple build and the
Tor scenario both passed on that head), and a *fresh site with its own container* still
loads direct. Only the very first WebView in the process uses its proxy. So the
discriminator is not the store's history and not the container's cache — both of which
attempt 8 addressed — but something that distinguishes the first WebView in a process
from every one after it.

The obvious candidate is WebKit's shared network process: `proxyConfigurations` may only
be read when that process is launched, in which case no store-level fix can work and
per-WebView proxies are simply unavailable after the first. That is a hypothesis, and
three hypotheses have already been wrong here, so this attempt measures instead of
arguing. The fork now prints, per WebView, whether `proxySettings` arrived and which
`WKWebsiteDataStore` the configuration ended up with, and per container-store lookup
whether it was built or reused and with how many proxy rules. The verdict line also
carries `containers=`, because whether the test resolved containers at all is a
precondition the truncated tier log did not show.

Also fixed: `Socks5Fixture.bind` subscribed to its server socket directly, so a socket
error at teardown surfaced as "(setUpAll) failed after test completion" and counted as
a fourth failure. It goes through `listenFixture` now, which exists for exactly that.
**Why:** the count said three hypotheses were wrong; only the plugin's own account of
what it did can say which one to replace.
**Why it was partial:** it is instrumentation. It fixes nothing, and if the network
process is the mechanism then the fix is not in this repo or in the fork.


### Attempt 10 — Containers were on, and the diagnostics went nowhere
**Date:** 2026-09-16 · **Files:** fork @ `49ee7c0`, `pubspec.yaml`,
`integration_test/proxy_binding_test.dart`, `integration_test/socks5_fixture.dart`
**What it did:** the verdict line answered the precondition and nothing else:

```
verdict: containers=true, first-in-process=proxied, fresh-site=DIRECT,
         refused=DIRECT, rebind=DIRECT
```

`containers=true`, so attempt 8's store rebuild *was* exercised: each site had a
container of its own, its store was built fresh with `proxyConfigurations` set at
construction, and the load still went direct. That rules out both store-shaped
explanations — the default-store singleton and the cached-store reuse.

The native diagnostics added in attempt 9 produced **nothing**: `flutter test` does not
capture the host app's stdout, so every `print()` from the plugin was discarded. An hour
of CI bought one bit. They go to a file in `NSTemporaryDirectory()` now, which the test
reads and prints from `tearDownAll` — the test runs inside the app process, so both
sides see the same directory.

What the two runs together do establish, without any native trace: it is not that the
first WebView's configuration sticks process-wide. In the run whose first WebView was
proxied, the later loads did not go through that proxy either — `socks.targets` is
cleared per scenario and stayed empty. Later WebViews get *no* proxy, not the first
one's.

Also: `listenFixture` did not fix the "(setUpAll) failed after test completion" noise —
the stack still points at the server socket's subscription. The fixture now cancels
that subscription before closing the socket, so a connection accepted in between has
nowhere to land.
**Why:** three store-shaped hypotheses are now dead, and guessing a fourth without the
plugin's own account of what it did would repeat the mistake this file keeps recording.
**Why it was partial:** still instrumentation. The remaining candidates are that
`preWKWebViewConfiguration` does not see `proxySettings` on later WebViews at all, or
that WebKit only honours `proxyConfigurations` for the first store a process uses. The
trace names which.


### Attempt 11 — The plugin's own account: it does everything right and the load goes direct
**Date:** 2026-09-16 · **Files:** fork @ `d71cce7`, `pubspec.yaml`
**What it did:** the file-based trace worked, and it ends the guessing. Per WebView, in
order, with `containers=true`:

```
built ws-proxy-binding-fresh   proxyRules=1
webview proxySettings=true containerId=ws-proxy-binding-fresh   store=0x…8418b8000
built ws-proxy-binding-seam    proxyRules=1
webview proxySettings=true containerId=ws-proxy-binding-seam    store=0x…8417aea80
built ws-proxy-binding-refused proxyRules=1
webview proxySettings=true containerId=ws-proxy-binding-refused store=0x…8418b9900
built ws-proxy-binding-rebind  proxyRules=0
webview proxySettings=false containerId=ws-proxy-binding-rebind store=0x…841683980
built ws-proxy-binding-rebind  proxyRules=1
webview proxySettings=true containerId=ws-proxy-binding-rebind store=0x…841683980
```

Every link in the chain checks out for `fresh-site`: the field crossed the channel
(`proxySettings=true`), `ProxySettings.fromMap` produced a rule (`proxyRules=1`), the
store is its own (a distinct `ObjectIdentifier`), it was **built** rather than reused,
and `proxyConfigurations` was assigned at construction. The load went direct anyway.
Only the first WebView in the process is ever proxied.

And attempt 8 was a no-op on top of that: the two `ws-proxy-binding-rebind` lines carry
the **same** `ObjectIdentifier` although the second says `built`.
`WKWebsiteDataStore(forIdentifier:)` is itself cached by WebKit — the same UUID returns
the same object — so "rebuild the store to get a clean one" cannot work, and the
rebuild machinery is removed. What remains is applying the proxy where the store is
first created, which is correct and is the only assignment WebKit honours.

So the remaining explanation is the one that needs no code in this repo:
`WKWebsiteDataStore.proxyConfigurations` is honoured for the first data store a
process's networking uses and ignored for every one after it. Every store-shaped fix
is dead, and so is every settings-parse-shaped fix.

This also matches the report exactly. The app builds WebViews lazily, so whether a
proxied site works depends on whether it happened to be the first WebView of the
session — "sometimes I have to restart the app for the Tor proxy to start working",
and "two sites, one on Tor, both showing my direct IP" when an unproxied one was built
first.
**Why:** four hypotheses were argued; this one is the plugin reporting what it did.
**Why it was partial:** it identifies the wall, it does not get over it. The next
measurement worth making is whether the rule is "first store" or "before the first
load": if the latter, pre-creating every site's store with its proxy at startup, before
anything loads, would work for sites whose proxy is known then — which excludes Tor,
whose port is not known until the runtime is up.


### Attempt 12 — Pin the fork's own tag, and measure what it does
**Date:** 2026-09-16 · **Files:** `pubspec.yaml`
**What it did:** the fork now carries a release tag, `v6.2.0-beta.3-privacy-v7`
(`bf5fbc3`), and all six `dependency_overrides` pin it instead of a bare SHA — which
is what [CLAUDE.md](../../CLAUDE.md) asks for ("tag it before each release") and closes
the mutable-ref hazard the pin has carried all along.

The tag is **not** on the lineage attempts 8-11 were built on. It carries its own
`proxySettings` parse fix (`c002242`, same shape as the `d128d89` this branch pinned)
plus work from a parallel session, of which one commit bears on this bug:
`3c5a43f`, "[ios/macos] fan the process-wide proxy override out to container data
stores" — `ProxyController.setProxyOverride` only ever touched
`WKWebsiteDataStore.default()` and `.nonPersistent()`, so a container-bound WebView
never saw it, and `getOrCreateDataStore` now replays a remembered override onto stores
created later.

What the tag does **not** carry is attempts 8-11: the store-at-creation proxy
assignment, the store rebuild, and the file-based diagnostics. Losing the first two
costs nothing measurable — attempt 11 showed the rebuild was a no-op
(`WKWebsiteDataStore(forIdentifier:)` is cached by WebKit) and that assigning at
creation binds no better than assigning after. Losing the diagnostics costs the
measurement: the `[proxy-binding] native:` lines came from the fork, so this run
reports only the Dart-side `verdict:` line.

Note that `3c5a43f` fixes the *process-wide override* path, not the per-WebView
`proxySettings` path that attempt 11 measured, and its own commit message says
`preWKWebViewConfiguration` still assigns `proxySettings` to the store after the
container bind returns — which is the assignment attempt 11 found is honoured only for
the first WebView in a process. So the expectation is that `fresh-site` is still
`DIRECT` on this tag; the run says whether that is right.
**Why:** a tag is the pin the repo asks for, and the parallel fix is worth measuring
before building anything further on top of it.
**Why it was partial:** it changes the pin, not the mechanism. If the verdict is
unchanged, the next step is a branch off the tag carrying only the diagnostics, and the
question attempt 11 left open: is the rule "first store in the process" or "any store
configured before the first network load"?


### Attempt 13 — The tag measures the same, on a second lineage
**Date:** 2026-09-16 · **Files:** none (measurement)
**What it did:** `v6.2.0-beta.3-privacy-v7` compiles and ships — the Apple builds and
the Tor scenario are green on it — and the gate reports exactly what it did before:

```
verdict: containers=true, first-in-process=proxied, fresh-site=DIRECT,
         refused=DIRECT, rebind=DIRECT
native: no container-store trace was written
```

So the finding is not an artifact of one lineage. Two independently-written
`proxySettings` parse fixes (`d128d89` and `c002242`), with and without the
store-at-creation assignment, produce the same behaviour: the first WebView in the
process is proxied and every later one loads direct. `3c5a43f` does not change it,
which is consistent with its own description — it repairs the *process-wide override*
reaching container stores, not the per-WebView `proxySettings` path.
**Why:** before proposing a different architecture, the old one should be shown to fail
on more than one implementation of it.
**Why it was partial:** it closes the per-WebView approach without opening another.
The live option is the one this app already runs on Android: drive the
**process-wide** proxy (`ProxyController.setProxyOverride`, which v7 now fans out to
container stores) and serialise sites whose proxies differ, the way PROXY-013 does
for Android's mismatched-proxy sites. That trades simultaneous per-site proxies for
proxies that work at all, and it is a user-visible trade, so it is not mine to make
unilaterally.


### Attempt 14 — Pin the v8 candidate, which reproduces the bug in the fork's own suite
**Date:** 2026-09-16 · **Files:** `pubspec.yaml`
**What it did:** repinned all six overrides to `privacy-v8-candidate` (`6b91b27`). Over
the v7 tag it adds the Android settings work and, for this bug, `01c5348`
"integration_test: reproduce *only the first WebView gets its proxy*" — the fork now
carries its own reproduction:

> The suite's proxy fixture answers every request with its own page rather than
> forwarding, which proves *that* a proxy was used but not *which* one, so it cannot
> see a second store silently falling back. […] The new test pins two container
> WebViews to different proxies and asserts each reports its own id. A is checked
> first so the failure is unambiguous: if only the first store in the process binds, A
> passes and B comes back null.

That is the same defect this file has been chasing, confirmed independently and from
the other side of the seam, with the same discipline the gate here arrived at: a
marker that only a correctly-bound proxy can produce, so a broken load cannot pass.
The `proxySettings` parse is present in the pinned checkout on both platforms.

No fix yet — `01c5348` reproduces, it does not repair — so the expectation is that the
verdict is unchanged. What it buys is a second, smaller harness to bisect in: the
fork's own example app, where the process-pool hypothesis can be tested without
rebuilding this app.
**Why:** the investigation has moved to the fork, and the app should be pinned to
where that work is happening.
**Why it was partial:** the pin is a mutable branch. `CLAUDE.md` asks for a tag before
each release, so this needs re-pinning to `…-privacy-v8` once the branch is tagged.


### Attempt 15 — Run the process-pool experiment here, because only here can it run
**Date:** 2026-09-16 · **Files:** fork branch `claude/per-webview-proxy-process-pool`
(`d39bc70`, off `privacy-v8-candidate`), `pubspec.yaml`
**What it did:** the fork's own reproduction (`01c5348`) cannot be executed where it was
written — the example app's integration suite needs a macOS host, Xcode and the node
fixture server. This repo's `build-apple` job has all three and has been the only
instrument in this investigation, so the experiment runs here.

The hypothesis, and the last one standing after attempts 4-13: every WebView is handed
`WKProcessPoolManager.sharedProcessPool` while carrying a *different*
`WKWebsiteDataStore`, and a `WKProcessPool` has historically been bound to one network
session. That would produce exactly the observed split — the first store's
`proxyConfigurations` is honoured, later ones are ignored — without anything being
wrong in WebKit, whose implementation is per-session on both delivery paths
(`SetProxyConfigData(m_sessionID, …)` and `networkSessionParameters.proxyConfigData`).

The branch gives a container-bound WebView its own pool, keyed by container id;
incognito keeps the shared pool, having no container. It also restores the file-based
container-store trace, now recording the *pool* identity alongside the store identity,
so the next verdict says whether the pools actually differ.
**Why:** it is the only untested explanation, it is cheap, and the agent working on the
fork cannot measure it.
**Why it was partial:** it is an experiment, not a design. If it works, whether a pool
per container is the right permanent shape is a separate question — process pools cost
memory and the fork shares one deliberately. If it does not work, the hypothesis dies
and with it the last store-shaped idea.


### Attempt 16 — The shared process pool was not it either
**Date:** 2026-09-16 · **Files:** fork `448b3ce`, `pubspec.yaml`
**What it did:** ran attempt 15's experiment and killed the hypothesis. The patch took
effect — the trace shows a distinct pool per container, which is what it was supposed
to produce:

```
webview proxySettings=true container=ws-proxy-binding-fresh   store=0x…6a4500 pool=0x…754600
webview proxySettings=true container=ws-proxy-binding-seam    store=0x…75d400 pool=0x…755200
webview proxySettings=true container=ws-proxy-binding-refused store=0x…6a4f00 pool=0x…754c00
```

Distinct pools, distinct stores, the field present, `proxyConfigurations` assigned —
and the verdict is unchanged. The pool change is reverted; only the trace is kept.

That exhausts every explanation of the shape "the WebViews share something they should
not". What is left is the shape nobody has tested: **the app's own mount pattern**.
Every scenario here replaces the whole widget tree, so the previous WebView is being
disposed while the next is built, and "first in the process" may really be "the only
one that was never built alongside a dying WebView". The next measurement is two
proxied WebViews mounted *simultaneously*, side by side, which needs no fork change at
all.
**Why:** four store/pool-shaped hypotheses have now failed. Continuing to guess at that
layer is the mistake this file keeps recording; the harness itself has never been a
suspect and it is the one thing common to every failing run.
**Why it was partial:** it removes a wrong answer. If simultaneous mounts both bind,
the defect is in the dispose/rebuild cycle rather than in binding at all — and the
user-visible bug would be narrower than feared.


### Attempt 17 — Not the rebuild cycle: two live webviews, neither proxied
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** ran attempt 16's experiment and killed the harness hypothesis too:

```
verdict: containers=true, first-in-process=proxied, side-by-side=0 of 2 proxied,
         fresh-site=DIRECT, refused=DIRECT, rebind=DIRECT
```

```
built ws-proxy-binding-side-a
webview proxySettings=true container=ws-proxy-binding-side-a store=0x…3c67ef80 pool=0x…99b2e00
built ws-proxy-binding-side-b
webview proxySettings=true container=ws-proxy-binding-side-b store=0x…3c014280 pool=0x…99b2e00
```

Two proxied webviews mounted in one tree, never replaced, each with its own
container store, both carrying the field — and the fixture proxy saw neither. The
scenario now also records where the two loads went instead, because a count of zero
otherwise has a second reading (neither load was issued at all) that says nothing
about binding; the next run reports `direct=` alongside it. So
"first in the process" is not "the only one never built alongside a dying webview":
nothing about the dispose/rebuild cycle is involved. The harness is exonerated, and
with it the last idea that did not require WebKit to be at fault.

What every run since attempt 7 has measured, now with no alternative reading left:
**only the first `WKWebsiteDataStore` in a process honours `proxyConfigurations`.**
Not the first webview of a site, not a store that has not yet loaded, not a store
that does not share a process pool — the first store, full stop. Five mechanisms
have been measured and eliminated: the settings parse, the default-store singleton,
cached-store reuse, rebuilding the store, and the shared `WKProcessPool`.

Also fixed: the tier runs one file per app process into one trace path, and only
`tearDownAll` deleted it, so the trace opened with webviews from earlier files'
processes (`ws-plain`, `ws-proxy-1`, a dozen `container=<none>` lines). Their pool
addresses differ from this file's, which is what made them separable by hand; the
trace is cleared in `setUpAll` now so it does not have to be.

A new scenario asks the one question that decides the design rather than the
mechanism: does the **process-wide** override (`ProxyController.setProxyOverride`,
which the pinned fork fans out to container stores) reach a webview built late in
the process? That is the Android PROXY-013 shape, and it is the only architecture
left. If it binds, per-site proxies survive as a setting and pay serialisation; if
it does not, no proxy of any kind can be applied to a second data store in an Apple
process, whoever assigns it.
**Why:** four store- and pool-shaped hypotheses failed, and the fifth (the harness)
has now failed too. Guessing at a sixth is the mistake this file exists to record.
The remaining question is not *why* the per-webview path fails but *what to ship
instead*, and that needs one fact about the alternative, not another theory about
this one.
**Why it was partial:** it fixes nothing, and it cannot: the choice it sets up is
a user-visible trade (simultaneous per-site proxies, or proxies that work at all)
and belongs to the user, not to this file.


### Attempt 18 — Read WebKit instead of guessing: it is registration order, not the store
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** stopped proposing mechanisms and traced `proxyConfigurations`
through WebKit's own source, end to end. The path is short and it contains one
ordering hazard that fits every measurement in this file.

`WKWebsiteDataStore.setProxyConfigurations:` (`WKWebsiteDataStore.mm`) unpacks each
`nw_proxy_config_t` and calls:

```cpp
// WebsiteDataStore.cpp
void WebsiteDataStore::setProxyConfigData(Vector<...>&& data)
{
    m_proxyConfigData = std::nullopt;                                   // (1)
    protect(networkProcess())->send(Messages::NetworkProcess::SetProxyConfigData(m_sessionID, data), 0);  // (2)
    m_proxyConfigData = WTF::move(data);                                // (3)
}
```

There are two ways the proxy can reach the network process, and they are not
equivalent:

* **In the session's creation parameters.** `WebsiteDataStore::parameters()` copies
  `m_proxyConfigData` into `networkSessionParameters` (line 2348), and
  `NetworkProcess::addWebsiteDataStore` builds the session from them eagerly
  (`m_networkSessions.ensure(sessionID, ...)`). `NetworkSessionCocoa`'s constructor
  ends with `if (parameters.proxyConfigData) setProxyConfigData(...)`.
* **As an update afterwards**, the `SetProxyConfigData` message at (2), which lands
  on an existing session and patches the live `nw_context_t` of each already-created
  `SessionWrapper`.

Step (2) is what *registers* a store the network process has not seen:
`WebsiteDataStore::networkProcess()` calls `NetworkProcessProxy::addSession(*this,
SendParametersToNetworkProcess::Yes)`, which sends `AddWebsiteDataStore {
store.parameters() }` **right there** — with `m_proxyConfigData` still `nullopt`
from (1). So the assignment that registers a session can never carry the proxy in
that session's parameters. Only the update path is left for it.

The one store that escapes is whichever is registered while the network process is
still coming up: `NetworkProcessProxy`'s constructor snapshots every existing store
(`parametersFromEachWebsiteDataStore()`), and that snapshot is read after
`setProxyConfigData` has returned and put the data back at (3).

That predicts exactly what six runs have shown, with no appeal to anything being
broken: **the first store the network process learns about gets its proxy through
the creation parameters and works; every later store has only the live-context
update, which does not take.** It is registration order, not the store, not the
pool, not the parse, not disposal — all of which this file eliminated one run at a
time.

The prediction is falsifiable in one run, so this attempt tests it rather than
asserting it — and the first scenario tests the *repair* rather than the diagnosis.
The snapshot is taken when the network process is constructed, so whether two stores
armed inside one turn of the run loop both land in it decides whether a repair
exists at all:

* **`side-by-side`** runs first now. Two container stores are built in one
  `pumpWidget`, before anything else in the process has touched the network. 2 of 2
  means the snapshot covers both, and the fix is to pre-arm every proxied site's
  container at startup instead of when its webview is built — per-site proxies
  survive with their containers intact. 1 of 2 means exactly one store per process
  can ever be proxied, and no pre-arming helps.
* **`second-container`** is the scenario that bound its proxy in every previous run,
  unchanged except that stores are registered ahead of it now. If it goes direct
  having passed before, registration order is the rule, measured rather than argued.
* **`global-early`** and **`global-override`** arm `ProxyController.setProxyOverride`
  on the default store and on a late container store respectively, because the
  fallback design would route proxied sites through one store and the two need to
  behave the same way when late.
**Why:** five runs of eliminating mechanisms by experiment cost five hours and never
produced a positive account of what *does* happen. The source produces one in an
afternoon, and it names a rule that can be tested by ordering alone.
**Why it was partial:** it is a diagnosis and its test, not a repair — and if the
rule holds, there is no repair on the client side. `setProxyConfigData` clears the
field before registering the session, so no sequence of public API calls can get a
proxy into a second store's creation parameters. What follows is a design: route
proxied sites through the one store armed before anything else and serialise sites
whose proxies differ (PROXY-013, the shape Android already runs), or accept one
proxied site per app launch.


### Attempt 19 — Confirmed by ordering: stores armed in one turn all bind
**Date:** 2026-09-16 · **Files:** none (measurement)
**What it did:** ran attempt 18's experiment. The verdict is the first positive
result this file has produced:

```
verdict: containers=true, side-by-side=2 of 2 proxied, direct=none,
         global-early=DIRECT, second-container=DIRECT, fresh-site=DIRECT,
         refused=DIRECT, rebind=DIRECT, global-override=DIRECT
```

**`side-by-side=2 of 2`.** Two container stores, each with its own proxy, built in
one `pumpWidget` before anything else in the process had touched the network: both
loads arrived at the fixture SOCKS server, and `direct=none` says neither fell back.
So more than one data store per Apple process *can* be proxied. Every earlier run
said otherwise only because the stores were armed one at a time.

**`second-container=DIRECT`.** This is the scenario that bound its proxy in all six
previous runs, when it was the first store the process registered. It is unchanged —
same site, same container, same proxy, same code — except that three stores are
registered ahead of it now, and it goes direct. Registration order is the rule, and
it is now established by ordering alone rather than by argument.

That confirms attempt 18's reading of WebKit: the proxy reaches the network process
either in the parameters that create a store's session or as a live update
afterwards, `setProxyConfigData` clears the field before the call that registers the
session, so the registering assignment can never carry it — and only the stores
already armed when the network process finishes coming up get the parameters path.
The live update does not take. `global-early` and `global-override` both being
DIRECT closes the last loophole: it is not about *which* store (default or
container) or *which* caller (per-WebView `proxySettings` or the process-wide
`ProxyController` override), only about when.

It also explains the report this file exists for, exactly. The app builds WebViews
lazily, so each proxied site's store is armed when its WebView is first built —
always after the network process is up, except for whichever site happened to be
opened first. "Two sites, one on Tor, both showing my direct IP" is the second site;
"sometimes I have to restart the app for the Tor proxy to start working" is the Tor
site happening to be first.

**The fix follows from the rule:** arm every proxied site's container store in one
batch at startup, before anything touches the network process, instead of at WebView
construction. That is attempt 20.
**Why:** six runs eliminated mechanisms without ever producing a positive account.
Reading Apple's source produced one, and it named an experiment that ordering alone
decides.
**Why it was partial:** it is the measurement, not the repair. It also bounds what
the repair can cover: a site that gains a proxy *after* startup, or is added
mid-session, still misses the window, and nothing in the public API reopens it.


### Attempt 20 — The fix: arm every proxied store at startup, in one call
**Date:** 2026-09-16 · **Files:** fork
`theoden8/flutter_inappwebview` @ `6705410` (`ContainerManager.swift` and the
container-controller Dart plumbing, iOS + macOS), `pubspec.yaml`,
`lib/services/webview.dart`, `lib/main.dart`,
`integration_test/proxy_binding_test.dart`,
`test/js/proxy_prearm_ordering.test.js`,
`openspec/specs/ip-leakage/spec.md`
**What it did:** acted on attempt 19's confirmed rule instead of assigning the
proxy where the WebView is built.

The fork gains `ContainerController.prepareContainers`, which takes a *list* of
`(containerId, proxySettings)` and creates and arms every one of those stores
synchronously inside one channel call. The app calls it once in
`_restoreAppState`, immediately after the container decision and before the proxy
router, the startup GC, the first cookie restore and the first WebView — the last
moment at which nothing has registered a network session. `WebViewFactory`'s
container and proxy resolution is extracted to `resolveStoreBinding` so the
pre-arm arms exactly the store and proxy the WebView will later be built with; a
pre-arm that disagreed would be worse than none, because the site would look
proxied and load through something else.

Two properties carry the fix and neither is visible at the call site, so both are
gated structurally in `test/js/proxy_prearm_ordering.test.js` (mutation-checked:
moving the call below `_activateProxyRouter` fails it). One call, because a call
per container is a run-loop turn per container and every turn after the first
misses the window. First, because anything that registers a session closes it.

The integration file is rewritten around the fix rather than around the hunt. The
scenarios that bisected the mechanism — side-by-side, the process-wide override at
both ends of the process, the demoted container — are gone; their conclusions are
attempts 15-19 and keeping them would be a wall of tests that now fail by
construction. What is left is positive: `setUpAll` pre-arms four sites exactly as
the app does, a first site loads through its proxy, and a **second site, built
after the first has already loaded, does too**. That second scenario is the fix,
and it is the exact shape of the report — "two sites, one on Tor, both showing my
direct IP" is that second WebView, and "sometimes I have to restart the app for the
Tor proxy to start working" is a restart making the Tor site the first one.
**Why:** the rule attempt 19 established leaves exactly one window in which a proxy
can be bound, and the app was not using it. Nothing else in the public API reaches
that window.
**Why it was partial:** it covers sites whose proxy is resolvable at startup, which
is every per-site HTTP/HTTPS/SOCKS5 proxy and the app-global outbound proxy. It does
not cover a proxy that becomes known later — a Tor runtime that reports its SOCKS
port after bootstrap, a site added or edited mid-session, an archive opened. Those
keep the old behaviour (bound only if opened first), and the honest next step is two
separate ones: make the app **fail closed** rather than load over the device IP when
a site's store was never armed, and pin Tor's SOCKS port at startup so Tor sites can
be armed in the batch like any other.


### Attempt 21 — The fix did not work: the window is keyed to the WebView, not the store
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** ran attempt 20 and it failed. The pre-arm executed exactly as
designed and changed nothing:

```
verdict: containers=true, prearmed=4, first=proxied, second=DIRECT,
         refused=DIRECT, rebind=not attempted
```

```
built ws-proxy-binding-first / -second / -seam / -refused
prepared 4 container(s), 4 proxied
reused ws-proxy-binding-first   webview proxySettings=true store=0x…fff200
reused ws-proxy-binding-second  webview proxySettings=true store=0x…fff700
```

Four container stores created and armed inside one channel call, before anything
in the process had touched the network, each `reused` afterwards by the WebView
that wanted it — and only the first WebView bound. `refused` reaching the origin
says the same thing from the other side.

So attempt 18's reading was wrong where it counts. Arming a store early does not
put it in the window; **the window is keyed to WKWebView creation.** Attempt 19's
`side-by-side=2 of 2` was not "two stores armed in one turn", which is what this
attempt built on — it was "two *WebViews* created in one turn", and the two
readings only diverge in the experiment that has now been run.

The correction matters for the shape of any fix. If the rule is the WebView, then
nothing in `ContainerManager` can help, and the app-level answer is to build every
proxied site's WebView in the first frame rather than lazily — which needs no fork
change at all.

Two variables changed between attempts 19 and 20 (the pre-arm was added, and the
two WebViews moved into separate turns), so neither run attributes on its own. The
file now holds the pre-arm and puts two of its sites back into one `pumpWidget`,
first in the process. 2 of 2 means the pre-arm is harmless and the rule is WebView
creation; 1 of 2 means the pre-arm itself closed the window by registering every
store's session before any WebView existed, and it has to come out.
**Why:** a fix that measured as a no-op is a wrong model, not a tuning problem, and
the two candidate models differ by one scenario.
**Why it was partial:** it un-ships nothing yet. The pre-arm stays on the branch
until the next run says whether it is harmless or harmful, and the `prepareContainers`
entry point in the fork stays with it.


### Attempt 22 — The rule is the first frame, and the pre-arm comes back out
**Date:** 2026-09-16 · **Files:** `lib/main.dart`, `lib/services/webview.dart`,
`pubspec.yaml`, `integration_test/proxy_binding_test.dart`,
`test/js/proxy_binding_fixture.test.js`, `openspec/specs/ip-leakage/spec.md`
(deleted: `test/js/proxy_prearm_ordering.test.js`)
**What it did:** ran attempt 21's discriminator and got an unambiguous answer:

```
verdict: containers=true, prearmed=6, pair=2 of 2 proxied, direct=none,
         first=DIRECT, second=DIRECT, refused=DIRECT
```

Two sites mounted in one `pumpWidget`, first in the process: both proxied, and
`direct=none` says neither fell back. The same two single mounts that followed,
on stores armed in the same batch, both went direct — including `first`, which
was `proxied` in the previous run when *it* held the first frame. Nothing about
those sites changed but which frame built them.

So the rule is settled across three arrangements: **a WebView binds its proxy
only if it is created in the process's first frame.** Every WebView in that
frame binds; a WebView in any later turn does not. What is done to the data
store beforehand is irrelevant — attempt 20 armed six stores in one call before
anything touched the network and changed nothing, and attempt 19 bound two
stores that were armed at WebView construction. Attempt 18 read the ordering
hazard in `WebsiteDataStore::setProxyConfigData` correctly and drew the wrong
boundary from it: `side-by-side=2 of 2` was two *WebViews* in one turn, not two
*stores* armed in one turn, and those readings only diverge in the experiment
attempt 21 ran.

Attempt 20's fix is therefore removed rather than left in place: the startup
pre-arm, its structural gate, and the `prepareContainers` pin. An API that
measures as a no-op has no business in the app or in the fork, and leaving it
would read to the next person as though the problem were handled. The
`resolveStoreBinding` extraction stays — `_bindingFor` uses it and it is sound
on its own.

The integration file is rebuilt around the rule. One frame carries every
proxied site it uses: two on the live SOCKS5 fixture (both must be proxied),
one on a closed port (must fail closed — a bound proxy that refuses cannot
reach the origin), and one created with `about:blank` and navigated afterwards.
That last pane asks what the app fix costs: if a WebView only has to *exist* in
the first frame, the app can create one empty WebView per proxied site at
startup and keep lazy loading; if it has to *load* in that frame, every proxied
site fetches its page at launch whether the user opens it or not.
**Why:** three runs now agree on the rule, and the remaining question is the
price of satisfying it, not what it is.
**Why it was partial:** the app still builds WebViews lazily, so the bug is
live. The fix is `_loadedIndices` at startup carrying every proxied site — the
same mechanism that already auto-loads notification sites — plus failing closed
for the sites that cannot make the frame. The deferred pane decides which
shape.


### Attempt 23 — Measure the factors together instead of one per run
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** changed the method rather than the product.

Every run since attempt 15 has moved one variable and cost an hour, because the
macOS tier is the only instrument. That is backwards: a *run* is expensive and a
*scenario* is free. It is also how attempt 20 came to be built on a reading that
one extra scenario would have refuted — `side-by-side=2 of 2` had two
explanations, the source I had just read favoured one, and I implemented a fix
on it instead of separating them first.

So this run carries the open factors at once:

* **`deferred`** — a webview built in the first frame with `about:blank` and
  navigated afterwards. Decides whether a webview must *load* in that frame or
  only *exist* in it, which is the difference between the app creating one empty
  webview per proxied site at startup and every proxied site fetching its page
  at launch.
* **`persist`** — a webview that bound in the first frame, navigated to a second
  origin. Every scenario in this file so far has measured a webview's *first*
  load. If the binding covers only that one, building every proxied site in the
  first frame fixes far less than it appears to, and a site leaks on the first
  link its user follows. This factor should have been measured fifteen attempts
  ago.
* **`later-pair`** — two proxied webviews built together in a *later* frame.
  "First frame" is how the rule reads, but every pair that bound was also the
  process's first mount, so "any frame carrying more than one webview" fits the
  same data. The two differ in what the app must do.

The follow-up navigations run inside the same `testWidgets` as the mount, so the
tree under test is still attached; across tests it would not be, and the result
would be a timeout that reads like a missing binding. The two extra origins bind
their own ports because the fixture records CONNECT by `host:port` — a second
load to the same origin can reuse the first connection, which looks identical to
no proxy being asked.
**Why:** the remaining questions are independent of each other, and the cost
structure rewards answering them in one run. Four of the last five runs moved one
variable each.
**Why it was partial:** it is still instrumentation. It does not fix anything —
but it should be the last measuring run before the app change, because between
them these three factors determine what that change has to be.


### Attempt 24 — The boundary is the first frame, and a webview must load in it
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** ran the factorial. Three of the four factors came back, and one
was lost to a flaw in how the factorial was written:

```
verdict: containers=true, pair=2 of 2 proxied, direct=none,
         refused=failed closed, deferred=DIRECT,
         later-pair=0 of 2 proxied, direct=a+b
```

* **`refused=failed closed`** — for the first time in this file, a site whose
  proxy points at a closed port did *not* reach the origin. That is the
  positive control: the proxy is genuinely bound, not merely reported.
* **`later-pair=0 of 2, direct=a+b`** — two proxied webviews built *together* in
  a later frame both went direct. So the boundary is the **first frame**, not
  "any frame carrying more than one webview". Both readings fitted every
  previous run; they do not fit this one.
* **`deferred=DIRECT`** — a webview built in the first frame with `about:blank`
  and navigated afterwards went direct. **Existing in the first frame is not
  enough; the webview must load in it.** That sets the price of the app-side
  fix: not one empty webview per proxied site at startup, but every proxied
  site fetching its page at launch.

**`persist=` is absent, and that is the methodological failure.** The factors
were measured in sequence with an `expect` between them, so the `deferred`
assertion threw and the test ended before the persistence navigation ran — and
persistence is precisely the factor that decides whether any fix is worth
building. A factorial whose factors can suppress one another is not a factorial.
The file now records every factor first and asserts only at the end, where a
failing assertion cannot cost a measurement.

What persistence decides, so the next run is read correctly: if a binding covers
only a webview's first load, then building every proxied site in the first frame
leaks on the first link the user follows, no arrangement of frames repairs it,
and failing closed is the only honest option left. If it covers the webview's
life, the first-frame build is a real fix with a known cost.
**Why:** two of the three answers narrow the fix and the third prices it; the
missing one decides whether to build it at all.
**Why it was partial:** it fixes the instrument again rather than the product,
and it cost a run to a mistake in the instrument rather than in the hypothesis.


### Attempt 25 — persist=DIRECT, and the one confound that could overturn it
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`
**What it did:** the factorial came back complete:

```
verdict: containers=true, pair=2 of 2 proxied, direct=none,
         refused=failed closed, deferred=DIRECT, persist=DIRECT,
         later-pair=0 of 2 proxied, direct=a+b
```

**`persist=DIRECT`.** A webview that used its proxy for its first load went
direct on its second, and the persist origin recorded the request, so the load
happened and bypassed the proxy — not "no load". Every factor now points one
way, and the rule is narrower than "the first frame" was:

> Only the loads **issued in the process's first frame** are proxied. Not the
> webview, not the store: the load.

That fits all four results at once. `pair-a`/`pair-b`/`refused` loaded in the
first frame and bound; `deferred` existed in that frame but loaded later and
went direct; `later-pair` was created and loaded later and went direct; and a
webview that bound went direct on its next navigation.

If it holds, it is not a bug that can be worked around. Building every proxied
site in the first frame would proxy each site's landing page and leak every link
its user follows afterwards — worse than not shipping the feature, because the
app would report those sites as proxied.

**One confound has to be ruled out before that is stated as fact.** The
persistence navigation was issued by `nativeController.loadUrl`, from Dart. A
user never produces that; they click a link, and an in-page navigation is a
different path through WebKit. A conclusion this consequential must not rest on
a code path the product does not use.

It also sits badly against the report this file exists for. A user whose proxy
covered only the first load would have said "only the first page is proxied",
not "sometimes I have to restart the app for the Tor proxy to start working".
When a measurement and a field report disagree, one of them is measuring the
wrong thing, and here the measurement is the newer and less trusted of the two.

So `persist` is now measured twice in one run, on two webviews that both bound
in the first frame: `persist-inpage`, where `/pair-a`'s own page sets
`location.href` after five seconds, and `persist-loadurl`, the programmatic path
that produced this run's DIRECT. If the in-page one is proxied, this attempt's
conclusion is an artifact of the harness and the feature is deliverable. If both
are direct, it stands, and the only honest response is to fail closed.
**Why:** every other factor is settled; this is the one that decides whether
there is anything to build, and it has a live alternative explanation.
**Why it was partial:** it changes no product code. It is the last thing worth
measuring before the answer is either a fix or a statement that there cannot be
one.


### Attempt 26 — Both ways direct: the mechanism cannot carry the feature
**Date:** 2026-09-16 · **Files:** `openspec/specs/ip-leakage/spec.md`
**What it did:** measured persistence on both navigation paths, and the confound
attempt 25 held open is closed:

```
verdict: containers=true, pair=2 of 2 proxied, direct=none,
         refused=failed closed, persist-inpage=DIRECT, persist-loadurl=DIRECT,
         later-pair=0 of 2 proxied, direct=a+b
```

`persist-inpage=DIRECT`. A page that navigated *itself* — `location.href` set
from script inside the first-frame document, which is exactly what a user
produces by clicking a link — went direct. So the earlier DIRECT was not an
artifact of driving the webview from Dart.

**The result cannot be read as "the proxy was bound and failed."** In the same
run, `refused=failed closed`: a site whose proxy pointed at a closed port
reached no origin at all. That is what a bound proxy does when it cannot
connect — it fails the load, it does not fall back. A load that *arrives* at the
origin therefore had no proxy on it. The two results together make the reading
unambiguous.

The rule in final form:

> Only the network loads issued in the process's **first frame** are proxied.
> Not the WebView, not the store: the load.

And so `WKWebsiteDataStore.proxyConfigurations` cannot carry the per-site proxy.
There is no arrangement of frames, stores, containers or process-wide overrides
that gets past it — attempts 19-25 tried all of them. Building every proxied
site in the first frame, which is what attempt 24 was heading towards, would
proxy each site's landing page and leak every link after it, while the app
reported those sites as proxied. That is worse than not offering the feature.

`LEAK-003` now states the rule and requires the app to fail closed on iOS and
macOS rather than present a proxy it can honour for one load. The Tor tier
inherits the same limit, because per-site Tor rides the same path.

One caveat kept deliberately: the verdict line appears twice in the job log
because the tier re-prints a failing file's last sixty lines. It is one
measurement, not a replication.

**Retracted the same evening, on the maintainer's challenge: does WebKit not
support this, and did we not confirm it does?** Both halves are right, and the
conclusion above was drawn too early.

WebKit's source says a bound session stays bound.
`NetworkSessionCocoa::applyProxyConfigurationToSessionConfiguration` puts the
proxy on the `NSURLSessionConfiguration` as each session wrapper is created,
which covers every load on that session rather than its first. Nothing in that
path expires after one load. The contradiction between that and the measurement
was noted several attempts ago ("trunk is symmetric; the shipping WebKit must
differ") and then built on anyway, which is the same error as attempt 20.

And the measurement does not isolate WebKit. Every scenario in this file builds
through `WebViewFactory`, which on Apple carries a navigation layer:
[ios-universal-link-bypass](../../openspec/specs/ios-universal-link-bypass/spec.md)
**cancels a main-frame link navigation and reissues it** through
`controller.loadUrl`, and the per-site policy cancels cross-site main-frame
navigations outright. So `persist-inpage` and `persist-loadurl` may have
collapsed into one path rather than being the two independent paths the
experiment was built to compare — which would also explain why they returned
identical results. A "second navigation" measured through the factory is not a
plain WebKit navigation.

It also fits the field report better than the retracted conclusion did: a proxy
that survives within a site and fails when the app re-issues a navigation is
what "sometimes I have to restart the app" sounds like.
**Why:** the conclusion removes a shipped feature on two platforms, so it had to
survive the explanations that would overturn it. One of them was not tested.
**Why it was partial:** it drew a product conclusion from an instrument that
still had this app's navigation policy inside it.

### Attempt 27 — Take the app out of the measurement
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`,
`openspec/specs/ip-leakage/spec.md`
**What it did:** added a scenario that builds an `inapp.InAppWebView` straight
from the plugin, carrying nothing but a `containerId` and `proxySettings` — no
`WebViewFactory`, no `shouldOverrideUrlLoading`, no universal-link bypass. It
loads once in the first frame and then navigates to a second origin.

`raw-first` / `raw-second` split the question the previous six attempts could
not: if the raw webview's second load is proxied, WebKit behaves as its source
says and the leak belongs to this app's navigation layer, where it is fixable.
If it goes direct too, the platform really does drop the proxy after the first
load and the earlier conclusion was right for the wrong reasons.

`LEAK-003` is walked back to what is actually established — later loads have
been measured going direct, and where that happens is not yet known — and no
longer requires failing closed, which was a normative claim resting on the
untested reading.
**Why:** the maintainer pushed back on a conclusion that contradicted the
source, and the pushback was correct.
**Why it was partial:** one scenario, one run. But it is the first one in this
file that measures the platform rather than the product.




### Attempt 28 — The raw webview was built in the wrong frame
**Date:** 2026-09-16 · **Files:** `integration_test/proxy_binding_test.dart`

```
verdict: … raw-first=DIRECT, raw-second=DIRECT …
native:  built ws-proxy-binding-raw
         webview proxySettings=true container=ws-proxy-binding-raw store=0x…aaed00
```

`raw-first=DIRECT`, and the trace shows the plugin did everything right: the
settings crossed, the container store was created, the proxy was on it. The
scenario still measured nothing, because it was written as its own
`testWidgets` and therefore ran *after* the first-frame test — so its webview
was built in a later frame, where by the rule established in attempts 22-24 it
cannot bind whatever is on it. It measured construction, not persistence.

That is the third harness error in this investigation, and they share a shape:
**the first frame is a scarce resource, and every probe has to be inside it.**
Sequenced assertions cost `persist` in attempt 24; measuring through
`WebViewFactory` cost the whole conclusion in attempt 26; and a probe placed in
its own test costs everything here. The raw webview is now a fourth pane in the
first frame beside `pair-a`, `pair-b` and `refused`, with its second navigation
taken inside the same test, and the comment beside it says why it cannot move.

`raw-first` is the floor for `raw-second`: if the raw webview does not bind in
the first frame, the second navigation says nothing either way. The factory's
programmatic navigation also gets its own origin back, since it had been
sharing a port with the raw one.
**Why:** the retraction in attempt 27 is only worth something if the experiment
that replaces it actually runs where it can produce a signal.
**Why it was partial:** it is the same experiment, placed correctly. It still
has to run.


### Attempt 29 — The app is exonerated; the platform drops the proxy after one load
**Date:** 2026-09-17 · **Files:** `integration_test/proxy_binding_test.dart`,
`openspec/specs/ip-leakage/spec.md`

```
verdict: … pair=3 of 2 proxied … raw-first=DIRECT, raw-second=DIRECT …
         raw webview first load  -> ok
         raw webview second load -> timeout
```

`pair=3 of 2` is the reading. Three panes in the first frame point at the main
origin — `pair-a`, `pair-b` and the raw plugin webview — and the fixture proxy
was asked for all three. **The raw webview's first load was proxied.** Its
`raw-first=DIRECT` label was a classifier bug, not a result: it keyed "direct"
off the origin recording `/raw`, and a *proxied* load reaches the origin too,
because the fixture relays it. Only the fixture's CONNECT log distinguishes
them, and only when each load has a target of its own.

With that corrected the isolating measurement reads:

> A webview built straight from the plugin — nothing on it but a container id
> and a proxy, no `WebViewFactory`, no `shouldOverrideUrlLoading`, no
> universal-link bypass, no per-site policy — bound its proxy for its first
> load in the first frame, and went **direct** on its second navigation.

So this app's navigation layer is exonerated. The retraction in attempt 27 was
the right move on the evidence then available, and the conclusion it retracted
turns out to have been correct: **only the first load a webview issues is
proxied.** Attempt 26 is reinstated, now on evidence that has no app code in it.

The harness is fixed rather than left to mislead the next reader: the raw pane
gets its own origin, "proxied" is computed from CONNECT counts per destination,
and the `direct=` field — which was never able to mean what it said — is gone
from the pair and renamed `arrived=` on the later-pair.

`LEAK-003` reinstates the fail-closed requirement with this as its evidence, and
records that the behaviour contradicts WebKit's own source
(`applyProxyConfigurationToSessionConfiguration` puts the proxy on the
`NSURLSessionConfiguration` for every session wrapper, which should cover every
load on that session). The shipping platform differs from trunk somewhere not
visible from the source; the observation governs.
**Why:** the question was whether the leak was ours or the platform's, and a
webview with none of our code on it answers it.
**Why it was partial:** the spec says fail closed and the code still does not.
Removing a feature the user built on two platforms is their call — the finding
is recorded and the decision is theirs.


### Attempt 30 — Test the instrument; then read the code the finding contradicts
**Date:** 2026-09-17 · **Files:** `integration_test/socks5_fixture.dart`,
`test/socks5_fixture_test.dart`, `integration_test/proxy_binding_test.dart`

Attempt 29's finding contradicts WebKit's source and contradicts published
audits of the same API ([Mysk, 2026-08][mysk] tested
`WKWebsiteDataStore.proxyConfigurations` for leaks and found only side channels
outside normal page loading — DNS prefetch, WebAuthn related-origin fetches,
WebTransport — not "everything after the first request"). A measurement that
disagrees with both is the thing to check, and every DIRECT reading in this
file came *later in the run* than a proxied one: an instrument that stops
partway through produces the whole result on its own.

[mysk]: https://mysk.blog/2026/08/04/webkit-proxy-icloud-private-relay-ip-leak/

So the SOCKS5 fixture is tested for the first time: ten sequential CONNECTs,
five overlapping ones, and one to a destination that refuses. **It records and
relays all of them.** The instrument does not lose CONNECTs, and the DIRECT
readings are not an artifact of it.

It did have a defect, and a bad one. The relay awaited
`upstream.listen(…).asFuture<void>()`, and `asFuture` *replaces* the
subscription's `onDone` and `onError` — so the `client.destroy` passed to
`listen` was discarded and every client socket was left open forever. The
integration file never waits for a close, which is why it never showed; the
self-test hangs on it immediately. Fixed by driving teardown from an explicit
completer.

Re-reading the WebKit side with the trace in hand, the shipping behaviour and
the source do not have a seam where attempt 29's rule could live:

* `WKWebsiteDataStore.setProxyConfigurations:` is unconditional
  (`WKWebsiteDataStore.mm`) and forwards to `WebsiteDataStore::setProxyConfigData`.
* That sends `SetProxyConfigData` after `networkProcess()` has registered the
  session, and restores `m_proxyConfigData` so any *later* session creation
  carries it in its parameters (`WebsiteDataStore.cpp:2348`). Attempt 18's
  ordering hazard is real in shape but closed in effect.
* In the network process, `NetworkSessionCocoa::setProxyConfigData` applies to
  every wrapper that exists, and `SessionWrapper::initialize` applies
  `applyProxyConfigurationToSessionConfiguration` to every wrapper created
  afterwards. Both directions are covered.

And the tier's own native trace says the plugin did its part for the panes that
went direct: `webview proxySettings=true container=ws-proxy-binding-late-a
store=ObjectIdentifier(0x…)`, a distinct store per pane, proxy assigned to each.

One mechanism in that source could still produce these readings: the live-update
path is `nw_context_clear_proxies` followed by `nw_context_add_proxy`, run over
the contexts of a session's wrappers. If that context is shared between stores
rather than owned by one, the newest store's proxy would be the process's only
proxy and every store configured before it would read as direct. A single proxy
fixture cannot see that — the signature is a load arriving at the *wrong*
fixture.

The next run therefore carries three new scenarios, all raw plugin webviews
with no app code on them:

* `sameturn-loadurl` — created in the first frame, loaded from that frame's own
  turn by `loadUrl`. Separates "the load must be issued in the first frame"
  from "the webview must be created in it"; those have never been separated.
* `raw-late` — created in a later frame with an initial request. `later-pair`
  was measured through `WebViewFactory`, and although its universal-link bypass
  is `hostIsIOS` and the tier is macOS, twice now a reading that looked like the
  platform turned out to be the app.
* `alt-proxy` — a second SOCKS fixture in that same later frame, with
  `crossed=` reporting whether either pane's destination arrived at the other's
  proxy.

**Why:** the user's objection was that a finding like this should be supported
by documentation and code, and it is contradicted by both. That makes the
harness the suspect, and the one component never tested was the instrument.
**Why it was partial:** the fixture is exonerated as a recorder but the
contradiction is unresolved — attempt 29's rule still stands as the only
reading of the data, and no run has yet distinguished the frame from the load
or looked for a crossed proxy.


### Attempt 31 — `sameturn-loadurl=proxied`: attempt 29's rule is refuted
**Date:** 2026-09-17 · **Files:** `integration_test/proxy_binding_test.dart`,
`openspec/specs/ip-leakage/spec.md`

```
verdict: containers=true, pair=2 of 2 proxied, refused=failed closed,
         persist-inpage=DIRECT, persist-loadurl=DIRECT,
         raw-first=proxied, raw-second=DIRECT,
         sameturn-loadurl=proxied,
         later-pair=0 of 2 proxied, arrived=a+b,
         raw-late=DIRECT, alt-proxy=DIRECT, crossed=false
```

Three readings, three eliminations.

**`sameturn-loadurl=proxied` refutes attempt 29.** A raw webview created in the
first frame with no initial request, navigated by `loadUrl` from that frame's
own turn, used its proxy. So "only the first load a webview issues is proxied"
is wrong: that load is the webview's second act, issued the way every DIRECT
reading in this file was issued. It is not the mechanism of the load and not a
per-webview budget of one.

**`crossed=false` excludes the process-wide clobber.** Two webviews carrying
*different* proxies in one later frame both went direct, and neither one's
destination arrived at the other's fixture. If WebKit's
`nw_context_clear_proxies` / `nw_context_add_proxy` update ran on a context
shared between stores, the newest store's proxy would be the process's only
proxy and the crossover would show. It does not.

**`raw-late=DIRECT` takes the app out of the late case.** `later-pair` was
measured through `WebViewFactory`; this is the same frame with nothing on the
webview but a container and a proxy, and it reads the same.

What survives is attempt 26's rule, not attempt 29's narrowing of it: **only a
load issued in the process's first frame is proxied — not the webview, not the
store, the load.** `LEAK-003` is corrected to say that, and gains the
`sameturn` scenario so the distinction cannot be lost again.

But "first frame" is a description of five single samples, and a clean cutoff
and a race that usually loses are indistinguishable when each scenario is
measured once. A race also fits the report this bug came from, which is not
"my first page is proxied and the rest are not" but *"sometimes I have to
restart the app for tor proxy to start working"* — and nothing measured so far
would tell the two apart.

So this run adds a staircase: one webview in the first frame, navigated five
times in succession, each step to an origin of its own, each recorded with the
elapsed time at which it was issued. A clean cutoff says rule. A ragged
pattern — proxied, direct, proxied — says race, and a race has a fix.
It runs before every other scenario in that test, because it is the only
time-sensitive one and the `waitReal` calls below it can burn twenty seconds
each.

**Why:** the finding was stated more narrowly than the evidence supported, and
everything that followed rested on it -- "the mechanism cannot carry the
feature" is a conclusion about the narrowed rule.
Separating the frame from the load was the cheapest way to test it, and it
came back against the narrowing.
**Why it was partial:** the rule is now stated correctly but still unexplained
— it contradicts WebKit's source, and no mechanism in that source survives the
`crossed=false` reading. Whether it is even a rule rather than a race is the
open question, and the staircase is the first measurement that can answer it.


### Attempt 32 — Not a race, and not the clock: the window closes on an event
**Date:** 2026-09-17 · **Files:** `integration_test/proxy_window_test.dart`,
`openspec/specs/ip-leakage/spec.md`

```
stair=[0ms:DIRECT 3025ms:DIRECT 6086ms:DIRECT 9128ms:DIRECT 12176ms:DIRECT]
sameturn-loadurl=proxied
```

Five consecutive navigations of one first-frame webview, every one direct, the
first at 0 ms. **So it is not a race** — a race that usually loses does not
produce five clean losses with no scatter — and **it is not elapsed time**,
because 0 ms is already on the wrong side of it.

Which leaves `sameturn-loadurl=proxied` next to `stair[0]=DIRECT` to explain,
and the difference between those two is the whole finding. Both are raw
webviews with a container and a proxy and no initial request, in the same
frame, navigated by `loadUrl`. The proxied one was navigated from inside
`onWebViewCreated`, as it was constructed. The direct one was navigated after
the tree had settled — by which time the four panes beside it had already
loaded.

So the rule is sharper than "the first frame", and `LEAK-003` now states it as
measured: a load is proxied only if the webview issues it **as it is
constructed**, and only if that webview is constructed in the process's first
frame. Attempt 31's `sameturn` reading was right about the frame and wrong
about what it isolated; this pins it.

And that shape points at an event rather than a frame. WebKit's
`WebsiteDataStore::setProxyConfigData` clears `m_proxyConfigData`, calls
`networkProcess()` — which registers the session and reads its parameters
right there — and only then restores the data:

```cpp
m_proxyConfigData = std::nullopt;
protect(networkProcess())->send(Messages::NetworkProcess::SetProxyConfigData(m_sessionID, data), 0);
m_proxyConfigData = WTF::move(data);
```

A store registered while that process is still launching has its parameters
read later, once the connection is up, with the proxy back in place. A store
registered against a process already running is read immediately, with the
proxy missing. Under that reading the whole suite's "first frame" is a
coincidence: the first frame is simply where the first load happens, and the
first load is what brings the network process up.

This is attempt 18's hazard, which attempts 19-22 discarded on the pre-arm's
failure — and it also explains that failure. `WKWebsiteDataStore.
proxyConfigurations =` calls `networkProcess()` itself, so the pre-arm's own
first store launched the process and every store after it was on the far side
of the window. `prearmed=4` was true and only the first of the four could have
bound.

`proxy_window_test.dart` separates the frame from the event, which nothing in
`proxy_binding_test.dart` can: it spends its own first frame on an *unproxied*
load, which brings the network process up and does nothing else, and builds
the proxied pair in the second frame. One file per app process is what makes
that possible.

* **2 of 2 proxied** → the window is the widget frame and the network process
  is not what closes it.
* **0 of 2** → the window closes when WebKit's networking comes up, and arming
  every proxied store before anything touches the network is a repair rather
  than the no-op attempt 20 measured.

**Why:** the staircase was built to tell a rule from a race, and it answered
that and handed over the discriminator between two first-frame webviews that
no scenario had ever put side by side.
**Why it was partial:** the mechanism is a reading of WebKit's source that
fits all thirteen data points and is still untested; the leak is unchanged and
the app still does not fail closed.


### Attempt 33 — Read the whole proxy path in WebKit; the mechanism is not there

**Date:** 2026-09-17
**Commit:** (this one) — fork `2615203a6b9bfe9032f2f1982d8f4483bc637f4d`

Attempt 32 proposed a mechanism and shipped an experiment for it. The
mechanism is refuted by the source it was read from, and so is the repair it
implied.

`WebsiteDataStore::setProxyConfigData` does clear `m_proxyConfigData`, call
`networkProcess()`, and restore it after. But `store.parameters()` is evaluated
synchronously at the `send()` call site inside `NetworkProcessProxy::addSession`,
which sits inside that window whether the network process is launching or
already up: `AuxiliaryProcessProxy::canSendMessage()` is `state() != Terminated`,
true during launch, and `sendMessage` queues into `m_pendingMessages` and
flushes them in order. So `AddWebsiteDataStore` always carries
`proxyConfigData == nullopt` and `SetProxyConfigData` always follows it on the
same ordered connection, onto a session `NetworkProcess::addWebsiteDataStore`
created eagerly. The `nullopt` is there to stop the proxy being applied twice,
not to race anything. There is no launching-vs-running asymmetry, so arming
every store before the network process comes up repairs nothing.

What the rest of the path says, read end to end:

* `NetworkSessionCocoa::setProxyConfigData` keeps the configs in
  `m_nwProxyConfigs` and patches every live wrapper's `nw_context`.
* `SessionWrapper::initialize` calls
  `applyProxyConfigurationToSessionConfiguration`, replaying
  `m_nwProxyConfigs` onto every `NSURLSession` made afterwards.
* `forEachSessionWrapper` covers the default set, the per-page sets and the
  per-parameters sets, including isolated sessions.
* `WebsiteDataStore::dataStoreForIdentifier` returns the *same* store for a
  UUID, so a container has one session and one stored proxy.
* `m_networkSessions.ensure` never replaces a session that exists.

So a store keeps its proxy for the life of its session, for every load, and
exactly one call removes it: assigning an empty `proxyConfigurations`, which
reaches `clearProxyConfigData`.

The fork had that call. `ProxyManager.setProxyOverride` wrote the process-wide
rule over every store in `ContainerManager.allCachedDataStores()` and
`clearProxyOverride` wrote `[]` over them — a global override replacing a
site's own proxy, and clearing the override dropping that site to the device
IP. Fixed: a store a webview binds with its own `proxySettings` is pinned
(weakly — a non-persistent store is transient) and skipped by the fan-out;
`releasePerSiteProxy` hands it back when a webview binds it naming no proxy,
so a site whose proxy was removed stops using the old one. Guarded by three
tests in each platform's `RunnerTests`.

**Why:** the finding had been challenged on the grounds that code and
documentation should support it, and they do not. Reading the path to the end
was the only way to find out which half was wrong.
**Why it was partial:** it does not explain the measurement. The scenarios in
`proxy_binding_test.dart` build webviews that never reach `ProxyManager`, so
the clobber cannot be what they saw — it is a second defect on the same seam,
found by the audit rather than by the test. The contradiction between the
source and thirteen data points is still open, the leak is unchanged, and the
app still does not fail closed.

### Attempt 34 — Bisect simultaneity, and test the other delivery route

**Date:** 2026-09-17
**Commit:** (this one)

Two confounds, both of this file's own making.

**"Two proxies at once" was only ever measured where one proxy does not
work.** `crossed=false` in attempt 31 was read as excluding a process-wide
proxy that the newest store overwrites. It excluded nothing: both of those
panes were in a later frame, where a single proxy goes direct anyway, so the
reading was of the frame. The arrangement that does bind -- a raw plugin
webview built in the process's first frame with an `initialUrlRequest` -- had
never been given a sibling carrying a different proxy.
`proxy_simultaneous_test.dart` puts four in that frame: panes 0 and 1 share
one SOCKS fixture, panes 2 and 3 get their own, so "two stores, one proxy"
(which `pair=2 of 2 proxied` already showed works) sits beside "two stores,
two proxies" in the same frame. The shared pair is first so the reading is
unambiguous: the first store built is pane 0 on fixture 0 and the last is pane
3 on fixture 2, so everything landing on fixture 0 means the first store kept
the process and everything landing on fixture 2 means the last one took it. Each pane has its own origin and every
fixture is checked for every origin, so a load landing on a sibling's proxy is
distinguishable from one that was never proxied. One fixture cannot make that
distinction, which is why the earlier reading could not have seen it.

**Every reading in this investigation was taken through a SOCKS5 proxy, and
SOCKS5 takes the fragile one of WebKit's two delivery routes.**
`NetworkSessionCocoa::setProxyConfigData` asks
`nw_proxy_config_stack_requires_http_protocols` about each configuration. If
any says yes it destroys and rebuilds every NSURLSession with the proxy on
that session's own `NSURLSessionConfiguration`
(`SessionWrapper::recreateSessionWithUpdatedProxyConfigurations`) -- per
session, nothing shared. If none does it patches the live `nw_context`
instead, clearing that context's proxies first, and it gathers those contexts
into an `NSMutableSet` across session wrappers, which is only worth doing if
two wrappers can hand back the same one. A SOCKS5 rule never takes the first
route. An HTTP CONNECT rule is the only way to ask for it from outside WebKit,
so `proxy_http_connect_test.dart` runs the same three-stores-three-proxies
shape over `HttpConnectFixture`.

Both instruments are tested before they are trusted, which is the lesson of
attempts 3, 28 and 29: `test/http_connect_fixture_test.dart` drives ten
sequential tunnels, five overlapping ones, a refused destination and an
absolute-URI request (a fixture that understood only CONNECT would record
nothing if WebKit ever sent the forward-proxy form, which reads exactly like a
proxy that was never asked). The relay both fixtures share is now one function
in `socket_relay.dart`, carrying the `asFuture()` fix from attempt 30 in one
place. Structural gates cover both new files: more than one proxy to tell
apart, a separate classification for a crossed load, a positive assertion
rather than a report, and the HTTP file's rules staying HTTP.

Two things found in WebKit's own tests while the run was building, both
worth having on record.

**Nothing upstream tests two stores with two proxies.**
`Tools/TestWebKitAPI/Tests/WebKit/WKWebView/Proxy.mm` has `HTTPSProxyAPI`,
`SOCKS5API`, `ProxyAfterNetworkProcessCrash`, `ProxyConfigurationAuthentication`
and the rest, and every one of them uses a single data store. That does not
prove the multi-store case is broken, but it does mean it is untested
territory upstream, which is consistent with what this tier keeps seeing.

**There is a second, durable per-store proxy path, and it is not
`proxyConfigurations`.** `NetworkSessionCocoa`'s constructor sets
`configuration.connectionProxyDictionary` from
`parameters.proxyConfiguration` (line 1216), and the ephemeral stateless
wrapper copies it off the credential-storage wrapper (line 1340), so it
reaches every session in the store. It is public `NSURLSessionConfiguration`
API, per session configuration, carried in `AddWebsiteDataStore` from the
start rather than arriving after the session exists -- no `nw_context`,
nothing shared. WebKit's own proxy-authentication tests use it, through
`_WKWebsiteDataStoreConfiguration`, which can carry both
`initWithIdentifier:` (the container) and `proxyConfiguration` (the dict), so
a store could have container isolation and its own proxy on that path.

It is not tested here, for a reason: `_WKWebsiteDataStoreConfiguration` and
`_initWithConfiguration:` are SPI, and the HTTP CONNECT arm above already
reaches the same destination without any -- `recreateSessionWithUpdated
ProxyConfigurations` puts the proxy on the session's own
`NSURLSessionConfiguration` too. So this is the fallback if HTTP CONNECT
turns out to carry simultaneous proxies and SOCKS5 is still needed natively
for Tor; an in-app HTTP CONNECT to SOCKS5 shim would answer that without SPI
either.

**Why:** the question the goal turns on -- can two data stores hold two
different proxies at once -- had never been asked where the answer could be
anything but no.
**Why it was partial:** written before the run reports; it measures rather
than repairs, and if HTTP CONNECT does carry simultaneous proxies then the
delivery change still has to be designed for Tor, which speaks SOCKS5.

### Attempt 35 — The instrument skipped; the window is not the widget frame

**Date:** 2026-09-17
**Commit:** (this one)

Run 3084 on `ba55523`.

**`proxy_window` reported, and it is a real reading:**
`warm=loaded, after-warmup=0 of 2 proxied, arrived=a+b`. The process spent its
first frame on an *unproxied* load, which arrived; the two proxied raw panes
built in the second frame both went direct. So the first frame is not special
because it is the first *frame* -- a frame spent on something else still
closes the window. Attempt 32 had called this branch "the network process
comes up", but attempt 33 refuted that mechanism from the source, so this
narrows by elimination rather than naming a cause.

Set beside `stair`, it sharpens the contradiction rather than resolving it.
The stair pane's store was built in the first frame -- the native trace shows
`built ws-proxy-binding-stair` there -- with its proxy on it, and all five of
its later navigations went direct. Same store, same proxy, same session.
WebKit's source says that cannot happen.

**The two new files measured nothing.** Both printed `proxySupported=false`
and skipped every scenario, because neither awaited `PlatformInfo.initialize()`
in `setUpAll`; `isProxySupported` is false until it runs. `proxy_window` in the
same run printed `proxySupported=true`, which is what gave it away. That is the
fourth harness error of this investigation and the third of the same shape: a
tier that cannot fail, reporting green. The tier prints a skip and a pass
identically, so nothing downstream caught it -- it was found by reading the
verdict lines by hand.

Fixed three ways rather than one, since this shape keeps returning:
`PlatformInfo.initialize()` is awaited in both files; the floor check is now an
`expect(..., isTrue)` with a reason naming the likely cause, because on an
Apple tier past the iOS 17 / macOS 14 floor a false reading means the
initialize was missed and skipping on it hides that; and a structural gate in
`test/js/proxy_binding_fixture.test.js` fails if any of the four Apple proxy
files reads `isProxySupported` without initializing first, or reads it before
the initialize. The gate was checked against the defect: removing the
initialize call makes it fail.

**`proxy_binding` is unchanged under the new fork pin**, as expected -- its
panes never reach `ProxyManager`, so the fan-out fix could not have moved
them: `stair=[0ms:DIRECT 3170ms 6258ms 9304ms 12358ms all DIRECT], pair=2 of 2
proxied, refused=failed closed, persist-inpage=DIRECT, persist-loadurl=DIRECT,
raw-first=proxied, raw-second=DIRECT, sameturn-loadurl=proxied, later-pair=0 of
2, raw-late=DIRECT, alt-proxy=DIRECT, crossed=false`. The native trace also
shows every container resolving to its own store and all of them sharing one
process pool.

**Why:** the simultaneity question and the HTTP CONNECT delivery question are
still unanswered, and this run was supposed to answer both.
**Why it was partial:** it answered neither. The only thing that moved is
`proxy_window`, and the instrument is now fixed rather than the bug.

### Attempt 36 — The chain, end to end: the proxy never reaches a session configuration

**Date:** 2026-09-17
**Commit:** (this one)

Reading `NetworkSessionCocoa`'s constructor to the end closes the gap between
what the source appeared to promise and what this tier keeps measuring. The
promise was read off `SessionWrapper::initialize`, which replays
`m_nwProxyConfigs` onto every NSURLSession it builds. The order is what
matters, and it runs the wrong way round:

1. `WebsiteDataStore::setProxyConfigData` sets `m_proxyConfigData` to
   `std::nullopt`, *then* calls `networkProcess()`. `parameters()` is read
   inside that call, so `AddWebsiteDataStore` always carries
   `proxyConfigData == nullopt` (attempt 33). The nullopt is deliberate --
   it stops the proxy being applied twice -- but it means the session is
   always created without one.
2. The `NetworkSessionCocoa` constructor calls
   `initializeNSURLSessionsInSet` (line 1258), which calls
   `SessionWrapper::initialize` **eagerly**. That calls
   `applyProxyConfigurationToSessionConfiguration` while `m_nwProxyConfigs`
   is still empty, so it takes the else branch and sets
   `configuration.proxyConfigurations = @[ ]`. The NSURLSession is built with
   no proxy.
3. The constructor's own `if (parameters.proxyConfigData) setProxyConfigData(...)`
   (line 1273) never fires, for the reason in (1).
4. The proxy arrives afterwards as its own `SetProxyConfigData` message. By
   then the wrappers exist and have sessions, so `forEachSessionWrapper`
   finds them and takes the **live `nw_context` patch** --
   `nw_context_clear_proxies` then `nw_context_add_proxy` -- because a SOCKS5
   configuration never makes `nw_proxy_config_stack_requires_http_protocols`
   true and so never sets `recreateSessions`.

So for every container store this app creates, the proxy exists **only** as a
patch on a live `nw_context`, and never in an `NSURLSessionConfiguration`. The
durable path that `SessionWrapper::initialize` provides is real, and nothing
here ever reaches it.

That is the first mechanism in this file that fits every reading rather than
some of them: a load issued while the patch is fresh is proxied (pair-a,
pair-b, refused, raw-first, sameturn), and anything later is not (stair at
0 ms and after, persist-inpage, persist-loadurl, raw-second, later-pair,
raw-late, alt-proxy). It also explains why the store being built in the first
frame does not help -- the store is fine, the session configuration under it
is what is empty -- and why `proxy_window` saw `after-warmup=0 of 2` even
though its first frame held an unproxied load.

Apple's own test suite is arranged the same way, which is worth more than it
looks. `Proxy.mm`'s durability test -- `ProxyAfterNetworkProcessCrash`, which
kills the network process, waits for a new one and asserts the proxy still
works -- is written with `nw_proxy_config_create_http_connect`. The SOCKS5
test beside it, `SOCKS5API`, issues exactly one load and never checks that the
proxy survives anything. So upstream exercises persistence only on the HTTP
CONNECT path and exercises SOCKS5 only for a single request, which is exactly
the split this chain predicts. It is corroboration rather than proof: nobody
has seen `nw_proxy_config_stack_requires_http_protocols` return a value here,
and that one unobserved bool is what the whole prediction rests on.

It predicts the arm already in flight. An HTTP CONNECT configuration should
make `requiresHTTPProtocols` true, which sets `recreateSessions`, which runs
`recreateSessionWithUpdatedProxyConfigurations`: that rebuilds each
NSURLSession from a configuration that
`applyProxyConfigurationToSessionConfiguration` has just written
`m_nwProxyConfigs` into. Durable, per session, nothing shared. If
`proxy_http_connect_test.dart` comes back with its three panes on their own
proxies while the SOCKS5 file does not, this chain is confirmed and the repair
follows from it.

Sharper still, on a second read of the ordering: the constructor calls
`initializeNSURLSessionsInSet` at line 1258 and only reaches its
`if (parameters.proxyConfigData)` at line 1273. So even in the case where
`AddWebsiteDataStore` *does* carry a proxy, the default session set's wrapper
has already been built from a configuration written with `@[ ]`, and the
proxy still lands as a live-context patch. `initializeNSURLSessionsInSet` has
exactly two callers -- that one, and line 1741 for a per-parameters session
set created later, where `m_nwProxyConfigs` is populated by then and the
proxy does go on durably. **The default wrapper, which is what an ordinary
page load uses, never carries the proxy on its `NSURLSessionConfiguration`
under any path.** `recreateSessionWithUpdatedProxyConfigurations` is the only
route that puts one there, and only an HTTP-protocol proxy stack triggers it.

The repair that follows is written and tested ahead of the verdict:
`lib/services/local_proxy_relay.dart`, one loopback HTTP CONNECT endpoint
that every store points at, fanning out per site by proxy-auth credential.
Two sites on two SOCKS5 upstreams reach their own and do not cross
(`test/local_proxy_relay_test.dart`), an unattributable tunnel is challenged
rather than relayed, and an upstream that cannot be reached returns 502
rather than dialling direct -- the two properties that decide whether this is
a proxy or a leak. It is deliberately **not wired** to `WebViewFactory` yet;
wiring every Apple proxy through a relay on a prediction, before the
prediction is tested, is the wrong order on a leak path.

`proxy_relay_binding_test.dart` tests it through WebKit without changing app
behaviour: raw plugin webviews point their own `proxySettings` straight at
the relay, four sites, four upstream SOCKS fixtures, one endpoint, one
credential each. Two panes in the first frame and -- the reading this bug
turns on -- two in a **later** frame, which is where every previous
arrangement went direct. `ProxyRule` already carries `username`/`password`
and the fork maps them to `applyCredential`, so no plugin change is needed to
run it. If the later-frame pair each reach their own upstream, both halves of
the defect are answered at once: the proxies are simultaneous *and* they
survive past the first frame, because the delivery now takes the durable
route.

One false negative was removed from that instrument before it ran. The relay
closed the connection after its `407`, which is fine for a client that
reconnects and wrong for one that retries in place -- and a credential
supplied through `applyCredential` may only be sent once challenged. That
would have produced a dead load, which this file reads as `no load` and which
would have been written up as WebKit ignoring the proxy rather than the relay
hanging up on it. The challenge is now a bounded loop on the same connection,
with a test that presents no credential, takes the 407, and retries on the
same socket.

**Why:** every previous mechanism here was proposed from a fragment of the
path. This one is the whole path, in order.
**Why it was partial:** untested until the HTTP CONNECT arm reports, and it
names no fix by itself -- the delivery has to change, since nothing outside
WebKit can make a SOCKS5 rule take the other route.

### Attempt 37 — The readings are not deterministic, and two arms were unfair

**Date:** 2026-09-17
**Commit:** (this one). Run 3089 on `97e902c`.

**The headline invalidates a lot of this file.** `proxy_binding_test.dart` is
byte-identical across the runs on `0a444e7`, `ba55523` and `97e902c` -- so is
`socks5_fixture.dart`, and so is the fork pin -- and its verdict changed:

* `ba55523`: `... raw-late=DIRECT, alt-proxy=DIRECT, crossed=false`
* `97e902c`: `... raw-late=proxied, alt-proxy=proxied, crossed=false`

Same code, same runner image, same everything, opposite results on two
scenarios. **These measurements are nondeterministic**, and every rule in this
file was drawn from one sample per scenario. "Only a load issued as the
webview is constructed is proxied" and its predecessors were read off single
draws; at least two scenarios demonstrably draw both ways. Attempt 31 worried
about exactly this ("a clean cutoff and a race that usually loses look alike
when each scenario is measured once") and the staircase was built to settle
it -- but the staircase only ever varied time within one run, never repeated a
scenario across runs.

This does not refute attempt 36's chain; it fits it. A proxy that exists only
as a patch applied to a live `nw_context`, after the session already exists,
is applied asynchronously and races the load that follows it. A live-context
patch is exactly the shape that produces a rate rather than a rule. What is
refuted is the idea that any of these single readings names a boundary.

**Two of the three new arms were not fair tests.** `proxy_http_connect` and
`proxy_relay_binding` both came back with every pane DIRECT and every proxy
fixture showing `connects=[]` -- WebKit never contacted them at all. The
likely reason is that both present a **plaintext** HTTP CONNECT proxy, and
every HTTP-proxy test in WebKit's own `Proxy.mm` uses
`HTTPServer::Protocol::HttpsProxy`, a TLS-wrapped proxy; there is no plaintext
CONNECT proxy test upstream. It is not `requiresSecureHTTPSProxyConnection`,
which defaults to `false` (`WebsiteDataStoreConfiguration.h:364`).

Corrected before it cost a cycle: `Protocol::HttpsProxy` is **not** a
TLS-wrapped proxy. `HTTPServerCore.swift:252` builds `NWParameters(tls: nil)`
-- plaintext TCP -- then inserts the `HTTPSProxyFramer`, then inserts `tls()`
*above* it in the application protocol stack. So it is a plaintext CONNECT
proxy whose TLS belongs to the tunnelled destination. The fixture here is the
right shape and a TLS fixture would have been another invalid arm.

What actually differs is the **destination scheme**.
`ProxyAfterNetworkProcessCrash` loads `https://example.com/` through its
CONNECT proxy, and `SOCKS5API` loads plain `http://example.com/` through its
SOCKS proxy and is used. Upstream exercises a CONNECT proxy only with a TLS
destination, and both arms here load `http://`. A transport-level proxy
config might well decline to tunnel plaintext http, where the convention is an
absolute-URI request rather than CONNECT -- and `connects=[]` says WebKit
made neither. So the fair version of these arms needs an **https origin**,
which means a self-signed certificate and a webview accepting it through
`onReceivedServerTrustAuthRequest`, not a TLS proxy.

Worth noting separately: a proxy configuration WebKit will not use appears to
produce a **direct** load rather than a failure. SOCKS5 pointed at a closed
port still gives `refused=failed closed`, so failover is off there; an
unusable HTTP CONNECT configuration went direct instead. If that holds it is a
leak in its own right.

**Why:** the run was supposed to decide between two deliveries.
**Why it was partial:** it decided nothing. One arm is invalid (plaintext
proxy), one inherits that invalidity, and the control proved the whole
measurement series has been single-sampling a random variable. The instrument
needs repetition -- N draws per scenario and a rate in the verdict -- before
any further mechanism is proposed, and the CONNECT arms need TLS.

`proxy_rate_test.dart` is the first half of that, and it is the measurement
this file should have had at attempt 3. One scenario, eight draws: a webview
built in a later frame -- which is what the app is actually made of, since
only the first site a user opens is in the first frame -- with its own
container, proxy and origin each round, so no round can ride another's
connection. The verdict is `proxied=k of 8` plus the per-round list. Eight is
chosen so that a true rate of one in three misses every round less than 4% of
the time. It asserts `k == 8`, and a partial rate fails: a proxy used four
times in eight is not a proxy, and reporting it as one is the leak itself.

### Attempt 38 — The later-frame case is deterministic; the goal arm has still never run

**Date:** 2026-09-17
**Commit:** (this one). Run 35275274157 on `523798e`.

Two verdicts landed, and they are the first repeated measurements in this
file:

```
[proxy-rate] verdict: containers=true, proxied=0 of 8,
    rounds=[DIRECT DIRECT DIRECT DIRECT DIRECT DIRECT DIRECT DIRECT]
[proxy-rate] socks connects=[]
[proxy-http-connect] verdict: containers=true,
    http-connect=[h0->DIRECT h1->DIRECT h2->DIRECT],
    later-socks-control=DIRECT
```

both with `proxySupported=true` and `containers=true`.

**`0 of 8` is not a rate.** A webview built in a later frame, with its own
container, its own proxy and its own origin each round, went direct eight
times out of eight, and the SOCKS fixtures logged no connection at all. A
proxy that exists only as an asynchronous patch to a live `nw_context`,
racing the load, would have proxied some rounds. So attempt 37's
nondeterminism is real but narrower than it looked: it belongs to the
scenarios `proxy_binding_test.dart` measures (`raw-late`, `alt-proxy`), which
still need their own rate file, and not to the plain later-frame case, which
fails deterministically. That case is what the app is made of -- only the
first site a user opens is in the first frame.

**The two https arms produced no output at all.** The loop entered both files
-- the group markers are in the log -- and the log carries three occurrences
of `openssl is not installed; cannot serve an https origin`. Both skipped on
the guard I wrote. The macOS integration tier runs a built app bundle:
`Process.runSync('openssl', ...)` there has no shell and no PATH to find a
binary on. Tor's own log in the same run reports "We compiled with OpenSSL
30600030: OpenSSL 3.6.3", so the library is present and only the CLI is out
of reach. A skip and a run are indistinguishable in the tier's output; this
is the fourth instrument in this file to report nothing and look like it
reported something, and the first to do it to the arm written to settle the
question.

**Simultaneity is not the defect, and this run settles it.** Extracted from
the same log after the fact, because the first pass read only the two arms
that had been rewritten:

```
[proxy-simultaneous] verdict: containers=true,
    first-frame=[p0->own(socks0) p1->own(socks0) p2->own(socks1) p3->own(socks2)],
    later-frame=[l0->DIRECT l1->DIRECT]
```

Four data stores, three distinct SOCKS5 upstreams, all built in the process's
first frame: every pane reached its own. Two stores sharing one proxy (p0, p1)
and two stores holding different ones (p2, p3) work at the same time, and
nothing crossed. This is the first reading of that file -- it was one of the
two that skipped for the uninitialized `PlatformInfo` -- and it answers the
question the whole line of work was pointed at: **per-data-store proxies do
work simultaneously on macOS.** What fails is the frame, not the count. Every
later-frame reading in the same run is DIRECT: `later-frame=[l0 l1]`,
`later-pair=0 of 2`, `after-warmup=0 of 2`, and `proxied=0 of 8`.

The one contrast left unexplained is that `[proxy-http-connect]` went DIRECT
on all three panes **in the first frame**, with all three proxy fixtures
empty, under the same containers and the same frame that SOCKS binds four of
four in. Same arrangement, different proxy type, opposite result. That is
attempt 37's prediction -- a CONNECT proxy declining a plaintext http
destination -- and the https arm below is what tests it.

**What this attempt did:** `integration_test/self_signed_cert.dart` mints an
RSA-2048 / SHA-256 self-signed certificate in Dart -- pointycastle for the
key, asn1lib for the DER -- carrying the routable address and `127.0.0.1` in
its subjectAltName. `test/self_signed_cert_test.dart` is its gate, and it
asserts the property the arms need rather than that a certificate parses: a
client trusting only that certificate completes a handshake by IP and by
name, an ordinary client is refused, and a client that overrides the check
gets through, which is the panes' own posture. Both https arms and
`test/outbound_https_proxy_hop_test.dart` now use it and no longer skip.
Two structural rules in `test/js/proxy_binding_fixture.test.js`, each checked
by mutating the file under test until it failed: nothing under `test/` or
`integration_test/` may `Process.run('openssl', ...)`, and the two https arms
must mint a certificate, serve it through `HttpServer.bindSecure`, and load
`https://` origins built from the routable address.

**Why it was partial:** the arm that decides the goal still has not executed
once. `proxy_relay_binding_test.dart` -- four sites, four upstream SOCKS
fixtures, one `LocalProxyRelay` CONNECT endpoint, one credential each -- has
been written, rewritten for TLS, and skipped. Everything here removes a
reason it could not run; none of it is a reading. The `0 of 8` does narrow
the ground it will land on: for a later-frame store the failure is total, so
the next run either shows the CONNECT route reaching the relay, in which case
the repair works and the delivery was the variable, or shows WebKit not
contacting any proxy for such a store, in which case attempt 36's chain is
the whole story and the fix has to be a store that is never asked to take a
proxy late.

### Attempt 39 — The certificate serves; the gate on it asserted the wrong thing

**Date:** 2026-09-17
**Commit:** (this one). Run 35283273289 (3096) on `17f9485`.

The run never reached the proxy arms. `fvm flutter test` -- the plain Dart
tier, step 18 -- failed `3277 passed, 3 failed`, which skipped `Build macOS`,
after which every integration file reported "Unable to start the app on the
device" and the tier printed a failure list naming all nineteen. One
unit-test failure, nineteen lines of noise, and no reading.

All three failures were attempt 38's own, and all three were the same shape:

```
HandshakeException: Handshake error in client (OS Error:
    CERTIFICATE_VERIFY_FAILED: application verification failure(handshake.cc:298))
```

**The certificate itself is fine, and the same run proves it.**
`outbound_https_proxy_hop_test.dart` passed all three of its tests on macOS
-- including the one that had never executed there, because it was the test
`skip: skip` used to hide when `openssl` was missing. That file stands up a
TLS CONNECT proxy and a nested TLS origin on this certificate. So a
Dart-minted certificate serves TLS on the macOS tier, which is what the https
proxy arms need.

What failed was every test that handed the certificate to
`setTrustedCertificatesBytes` and let the platform's trust policy decide.
Apple's SSL policy refuses it as an anchor where BoringSSL accepts it; the
tests that used `badCertificateCallback` passed on the same runner. The
assertion was asserting something **no caller relies on**: the WebView panes
answer `onReceivedServerTrustAuthRequest` with PROCEED, and the Dart-side
clients pin by sha256. A gate that tests a path the product does not take,
on one platform only, is a cost with no coverage behind it -- and this one
cost the run it was gating.

Fixed two ways. The generator now emits a real server leaf: `keyUsage`
(critical), `extendedKeyUsage` serverAuth, subject and authority key
identifiers alongside the basic constraints and the subjectAltName it
already had. Apple requires serverAuth on a TLS server certificate and
BoringSSL treats an absent `extendedKeyUsage` as any purpose, so its absence
was invisible on Linux; `openssl verify -purpose sslserver` now passes.
The tests assert identity instead of policy: the handshake completes and the
certificate the peer was handed is byte-for-byte the one this run minted.

**Why it was partial:** it is still not a reading. Three runs have now been
spent without the goal arm executing once -- 3094 skipped it on a missing
binary, 3095 was cancelled by the push that fixed that, 3096 died in the unit
tier before the app was built. Twice now the thing that stopped it was the
instrument rather than the subject. The one durable lesson is procedural and
is why this entry exists: attempt 38 ran the files it touched and not
`fvm flutter test`, which is what CI runs, and the whole suite takes under
three minutes here.

### Attempt 40 — Simultaneity is not established; it drew the other way

**Date:** 2026-09-18
**Commit:** (this one). Run 35288165002 (3097) on `8394683`.

Every arm executed. Step 18 passed, both builds passed, the Tor scenario
passed, Android passed, and the macOS integration tier ran all nineteen
files. The verdicts:

```
[proxy-binding]      pair=2 of 2 proxied, raw-first=proxied,
                     sameturn-loadurl=proxied, later-pair=0 of 2,
                     raw-late=DIRECT, alt-proxy=DIRECT, crossed=false
[proxy-simultaneous] first-frame=[p0->DIRECT p1->DIRECT p2->DIRECT p3->DIRECT],
                     later-frame=[l0->DIRECT l1->DIRECT], socks0..2 connects=[]
[proxy-rate]         proxied=0 of 8, socks connects=[]
[proxy-http-connect] http-connect=[h0->DIRECT h1->DIRECT h2->DIRECT],
                     proxy0..2 connects=[], later-socks-control=DIRECT
[proxy-connect-https] connect-https=[c0->DIRECT c1->DIRECT c2->DIRECT],
                     proxy0..2 connects=[]
[proxy-relay]        first-frame=[s0->DIRECT s1->DIRECT],
                     later-frame=[s2->DIRECT s3->DIRECT], socks0..3 connects=[]
[proxy-window]       after-warmup=0 of 2 proxied
```

**Attempt 38's headline is refuted.** `proxy_simultaneous_test.dart` read
`first-frame=[p0->own(socks0) p1->own(socks0) p2->own(socks1) p3->own(socks2)]`
on run 3094 and `[DIRECT DIRECT DIRECT DIRECT]` here, and
`git diff 523798e..8394683` touches neither that file nor
`proxy_binding_test.dart`, `socks5_fixture.dart` or `fixture_server.dart` --
only `pubspec.yaml`, for two dev dependencies. So "per-data-store proxies do
work simultaneously on macOS" was one draw, recorded as settled, and the next
run drew the other way. That is the same error attempt 37 named, committed
again two attempts later, and it is the reason this entry leads with it.

**The nondeterminism is per process, not per run.** In *this* run
`proxy_binding`'s first-frame pair proxied 2 of 2 while `proxy_simultaneous`'s
first frame proxied 0 of 4. Each integration file is its own app process, so
two processes in one run disagreed about the same nominal condition.

**What survives both runs, stated as a tally rather than a rule:**

* Proxied at least once: `pair` (two stores, **one** proxy, first frame),
  `raw-first`, `sameturn-loadurl`, and `proxy_simultaneous`'s first frame on
  3094 (four stores, **three** proxies).
* Never proxied in any run: everything after the first frame
  (`later-pair`, `later-frame`, `after-warmup`, `proxied=0 of 8`).
* **Never proxied, ever, in any arm: an HTTP CONNECT proxy.** Three separate
  arms across two runs -- `proxy_http_connect` (http destinations),
  `proxy_connect_https` (https destinations) and `proxy_relay` (https
  destinations through the relay) -- every pane DIRECT, every proxy fixture
  `connects=[]`, first frame and later frame alike. The origins' own request
  logs fired, so the loads went straight out; WebKit contacted no CONNECT
  proxy at any point.

**That kills two hypotheses at once.** Attempt 37 proposed the destination
scheme as the variable, because upstream WebKit only exercises a CONNECT
proxy with a TLS destination. The https arm exists to test it and reads
identically to the http arm, so the scheme is not it. And attempt 36's repair
rested on an explicitly unverified premise -- that an HTTP CONNECT
configuration makes `nw_proxy_config_stack_requires_http_protocols` true and
so takes `recreateSessions`, the one route that writes the proxy onto a
session's own `NSURLSessionConfiguration`. The relay is built entirely on
that premise. Whatever the function returns, a CONNECT configuration set
through `proxySettings` does not reach WebKit's network stack on this path at
all, so the premise cannot be relied on.

**Why it was partial:** the goal arm finally ran and the repair does not
work. `proxy_relay` is the cleanest refutation available -- four stores, one
endpoint, one credential each, the shared-configuration shape that `pair`
succeeds with -- and all four panes went direct with every upstream idle. The
one delivery that has ever bound a proxy here is SOCKS5, which is what the
relay deliberately does not speak. Nothing in this attempt is a fix; it is
the reading that says which direction the fix cannot be.

### Attempt 41 — The controls void three arms and name the real variable

**Date:** 2026-09-18
**Commit:** (this one). Run 35293313430 (3098) on `e01b8ad`.

The positive controls added in attempt 40 answered on their first run, and
what they say is that three arms have been reporting nothing:

```
[proxy-rate]          first-frame-control=DIRECT, proxied=0 of 8
[proxy-relay]         first-frame-socks-control=DIRECT,
                      first-frame=[s0->DIRECT s1->DIRECT],
                      later-frame=[s2->DIRECT s3->DIRECT]
[proxy-connect-https] first-frame-socks-control=DIRECT,
                      connect-https=[c0->DIRECT c1->DIRECT c2->DIRECT]
[proxy-binding]       pair=2 of 2 proxied, raw-first=proxied,
                      sameturn-loadurl=proxied, stair=[DIRECT x5],
                      later-pair=0 of 2, raw-late=DIRECT, alt-proxy=DIRECT
```

A control is one SOCKS5 pane in its own process's first frame -- the
arrangement `proxy_binding` binds in every run. All three read DIRECT. So
`proxied=0 of 8` is not a measurement of later frames, the relay's four
direct panes are not a measurement of relays, and the CONNECT arm's three
direct panes are not a measurement of CONNECT. **Every null result this file
has recorded from those arms is withdrawn**, including attempt 40's "no HTTP
CONNECT proxy has ever been contacted": that may still be true, but no arm
that could have shown it was in a state to show anything.

**What the controls establish instead is sharper than what they voided.** In
one run, on one machine, `proxy_binding`'s process bound a proxy three
different ways while three other processes bound none at all -- and run 3097
reads the same both ways. That is not a race across runs. Something differs
between `proxy_binding`'s app process and every other arm's, and it
reproduces.

Two further readings inside `proxy_binding` are worth keeping because they
cut against the rule this file has carried since attempt 32. Its `stair`
scenario is mounted **in the first frame** and every one of its five
navigations reads DIRECT, while `pair`, `raw-first` and `sameturn-loadurl`,
mounted in that same frame, proxy. So "built in the first frame" is not
sufficient; what those three share and the staircase does not is that the
load is issued as the webview is constructed, from that frame's own turn.

**What this attempt did:** `integration_test/proxy_shape_test.dart` puts the
three enumerable differences in one first frame, on one shared SOCKS5
endpoint, so a single run separates them -- a raw plugin webview loading from
`initialUrlRequest` (proxy_rate's control, which reads DIRECT), the same site
through `WebViewFactory.createWebView` (what `proxy_binding`'s pair panes and
the app itself use), and a raw webview loaded by `loadUrl` from
`onWebViewCreated` (`proxy_binding`'s `sameturn`). The fourth difference is
removed rather than measured: every arm now awaits `PlatformInfo.initialize()`
before asking about containers, which is the order `proxy_binding` uses and
the only arm that binds.

**Why it was partial:** it is an instrument, not a fix, and the four
differences it separates are the ones visible from reading the files. If the
verdict comes back with all three shapes direct, the variable is somewhere
this attempt did not look, and the next step is to bisect
`proxy_binding_test.dart` itself rather than to add another arm beside it.

### Attempt 42 — Not the shape, and the tier's own file order is a suspect

**Date:** 2026-09-18
**Commit:** (this one). Run 35297986025 (3100) on `3e6d2e5`.

```
[proxy-shape] verdict: containers=true,
    shape=[raw-initial->DIRECT factory->DIRECT raw-loadurl->DIRECT]
[proxy-rate]  first-frame-control=DIRECT, proxied=0 of 8
[proxy-relay] first-frame-socks-control=DIRECT, all four panes DIRECT
[proxy-connect-https] first-frame-socks-control=DIRECT, all three DIRECT
[proxy-binding] pair=2 of 2 proxied, raw-first=proxied,
                sameturn-loadurl=proxied, stair=[DIRECT x5]
```

Three webview shapes in one first frame on one shared SOCKS5 endpoint --
the raw plugin widget loading from `initialUrlRequest`, the same site
through `WebViewFactory.createWebView`, and a raw widget loaded by `loadUrl`
from `onWebViewCreated` -- and all three went direct. Normalizing every arm's
`setUpAll` to await `PlatformInfo.initialize()` before querying containers,
the order `proxy_binding` uses, changed nothing either. So none of the four
differences enumerable from reading the files is the variable, and
`proxy_binding` still bound a proxy three ways in the same run.

**The file order is the thing nobody has looked at.** The tier walks
`integration_test/*_test.dart` in glob order, so the sequence is
`... privacy_settings, proxy_auth, proxy_binding, proxy_connect_https,
proxy_http_connect, proxy_rate, proxy_relay_binding, proxy_shape,
proxy_simultaneous, proxy_window`. `proxy_binding` is the **first** file in
that list that asks for a proxy, it binds, and **every proxy file behind it
fails** -- across runs 3097, 3098 and 3100, whatever the frame, the delivery,
the destination scheme or the widget shape. Each file is its own app process,
so whatever carries over is outside the process: the app's sandbox container
on disk, a leaked `Webspace` process (the job's cleanup step has reported
`Terminate orphan process: pid (N) (Webspace)`), or something else the tier
does not control.

If that is right, this file's central rule -- that a proxy binds only in the
process's first frame -- is an artifact of measuring nine proxy files in a
row, not a property of WebKit. Run 3094 is the one reading that does not fit:
`proxy_simultaneous` bound 4 of 4 there while sitting behind `proxy_binding`,
so the carry-over is not absolute.

**What this attempt did:** the tier now runs `proxy_shape_test.dart` twice in
one run, once ahead of every other integration file and once in its
alphabetical position, and the arm prints `position=first` or `position=glob`
in its verdict. One file, one run, one machine, two positions. If the
verdicts differ, position is the variable and no reading this tier has
produced about frames means anything. If they are the same, the carry-over
theory is dead and the next step is to bisect `proxy_binding_test.dart`
itself by deleting scenarios until `pair` stops binding.

**Why it was partial:** it is still an instrument. It also does not explain
the user's report, which is about one app in normal use rather than nine app
processes in sequence; if position turns out to be the variable, the tier has
been measuring itself and the real defect still needs an instrument that
looks like the app.

### Attempt 43 — Position in the tier is the variable, and it retracts the central rule

**Date:** 2026-09-18
**Commit:** (this one). Run 35302350398 (3101) on `52015a4`.

One file, one machine, one run, two positions:

```
[proxy-shape] position=first, ... socks 49951
[proxy-shape] raw-initial -> proxied
[proxy-shape] factory     -> proxied
[proxy-shape] raw-loadurl -> proxied
[proxy-shape] socks connects=[192.168.64.9:49952, :49953, :49954]
[proxy-shape] verdict: position=first,
    shape=[raw-initial->proxied factory->proxied raw-loadurl->proxied]

[proxy-shape] position=glob, ... socks 50247
[proxy-shape] raw-initial -> DIRECT
[proxy-shape] factory     -> DIRECT
[proxy-shape] raw-loadurl -> DIRECT
[proxy-shape] socks connects=[]
[proxy-shape] verdict: position=glob,
    shape=[raw-initial->DIRECT factory->DIRECT raw-loadurl->DIRECT]
```

`proxy_shape_test.dart` is one file. It ran twice in this run, once ahead of
every other integration file and once in its alphabetical place. Ahead of
them all three shapes bound a proxy and the SOCKS fixture logged all three
origins. In its own place none of them did and the fixture was idle. Nothing
about the file, the frame, the widget shape, the delivery or the destination
changed between those two runs. **Only its position in the tier did.**

**What this retracts.** This file's central claim since attempt 32 -- that on
Apple a load is proxied only if the webview is constructed in the process's
first frame, and that everything after it leaks -- was measured by running
nine proxy files in a row and reading the ones behind the first. The first
one binds. The rest do not, whatever they do. So:

* "Only the first frame binds" is **withdrawn**. It was never separated from
  "only the first proxy file in the tier binds".
* `proxy_rate`'s `proxied=0 of 8`, `proxy_relay`'s four direct panes,
  `proxy_connect_https`'s three, `proxy_simultaneous`'s later frame and
  `proxy_window`'s `after-warmup=0 of 2` are all readings taken from that
  position and say nothing about their scenarios.
* `proxy_binding` binds because it is the first proxy file the glob reaches,
  not because of anything it does.

**The carry-over is outside the process, and the container directory is the
candidate.** Each file is its own app process, so the state that survives is
on disk. Attributing every `[Container/...]` line in run 3100's log to its
enclosing `::group::` file shows it accumulating: `proxy_auth_test.dart` swept
1 orphan container at startup, and `safari_navigation_test.dart` -- which runs
after every proxy file -- swept **47**. By the time the later proxy arms run,
dozens of stale `WKWebsiteDataStore` directories sit under
`~/Library/Containers/org.codeberg.theoden8.webspace/Data/`. No leaked-process
evidence was found: run 3100 logs no `Terminate orphan process` line.

The same mechanism would also explain the pattern *inside* `proxy_binding`.
Its first frame creates six stores at once and three of them bind; every
scenario after that frame -- `stair`, `later-pair`, `raw-late`, `alt-proxy` --
runs with those six already in existence and reads DIRECT.

If it holds, it also fits the report this bug started from: a user who
restarts the app gets a process whose store count starts over, which is
exactly "sometimes I have to restart the app for the Tor proxy to start
working".

**What this attempt did:** `proxy_shape_test.dart` now lists every existing
container at startup, deletes them all, and reports `swept=N` in its verdict.
It still runs twice. If `position=glob` binds once the directory is empty, the
carry-over is the stored containers and the next step is a threshold
measurement -- how many stores a process can create before one stops taking a
proxy. If it still goes direct with `swept` greater than zero, the carry-over
is something else and the on-disk containers are excluded.

**Why it was partial:** it names the variable but not the mechanism, and
every quantitative reading this file has recorded since attempt 32 now has to
be taken again from a valid position before any of it can be believed.

### Attempt 44 — The stored containers are not the carry-over

**Date:** 2026-09-18
**Commit:** (this one). Run 35307142863 (3102) on `25618b6`.

```
[proxy-shape] verdict: position=first, swept=0,
    shape=[raw-initial->proxied factory->proxied raw-loadurl->proxied]
    socks connects=[192.168.64.17:49943, :49944, :49945]
[proxy-shape] verdict: position=glob, swept=35,
    shape=[raw-initial->DIRECT factory->DIRECT raw-loadurl->DIRECT]
    socks connects=[]
```

Attempt 43's position effect reproduces exactly on a second run, so it is not
itself a draw. The new information is the sweep: in its glob position the arm
found **35 stored containers, deleted every one of them**, and then bound
nothing. Ahead of the tier it found none and bound all three.

The deletion was real rather than reported: `safari_navigation_test.dart`,
which runs after every proxy file and sweeps whatever is left, collected 12
orphan containers this run against 47 on run 3100, and 35 + 12 = 47. So the
arm removed exactly what it said it did, and binding did not come back.

**Stored `WKWebsiteDataStore` containers are excluded.** That was the
mechanism attempt 43 proposed, on the evidence that they accumulate across
app processes, and it is wrong. The count of stores on disk is not what
decides whether a later process binds a proxy.

What is still standing: something survives between app processes on this
machine, and the first process to ask for a proxy gets one. Everything else
in the app's sandbox container is still a candidate -- prefs, the WebKit
caches under `Library/WebKit/`, `Library/HTTPStorages/`, the default data
store -- and so is state outside it entirely (a system daemon, the runner
warming up, elapsed time).

**What this attempt did:** the tier now runs the same arm a third time, last,
after `rm -rf "$HOME/Library/Containers/org.codeberg.theoden8.webspace"`, as
`position=wiped`. One run then reads: ahead of the tier (binds), in place
(does not), and in place with the whole app container gone. If wiped binds,
the carry-over is disk state and the next step bisects which subdirectory. If
wiped does not bind, no app-owned disk state explains it and the search moves
off the app entirely.

**Why it was partial:** it eliminates a candidate rather than finding the
cause, and the elimination is only as good as `deleteContainer`, which the
sweep arithmetic corroborates but does not prove removes every byte the store
owned.

### Attempt 45 — It is app-owned disk state, and it is not position

**Date:** 2026-09-18
**Commit:** (this one). Run 35311297744 (3103) on `0935a2d`.

The same arm, three times in one run:

```
position=first, swept=0  -> [raw-initial->proxied factory->proxied raw-loadurl->proxied]
position=glob,  swept=35 -> [raw-initial->DIRECT  factory->DIRECT  raw-loadurl->DIRECT]
position=wiped, swept=0  -> [raw-initial->proxied factory->proxied raw-loadurl->proxied]
```

`position=wiped` is the **last** app launch of the tier: roughly twenty
launches and thirty-five minutes after the first one, with only
`rm -rf "$HOME/Library/Containers/org.codeberg.theoden8.webspace"` between it
and the glob run that bound nothing. It bound all three shapes.

**That narrows it twice over.** Position in the tier is not the variable
after all -- attempt 43 named it correctly as a correlate and wrongly as the
cause. Neither is elapsed time in the job, nor the number of app processes
already launched, nor anything about the runner warming up: the last launch
of the run behaves like the first once the container is gone. What decides it
is **state the app owns on disk**, and removing that state restores binding
at any point in the tier.

It is also not the stored data stores, which attempt 44 excluded by deleting
all 35 of them with no effect. So the carrier is something else under the
sandbox container: the preferences plist, `Library/WebKit/`,
`Library/HTTPStorages/`, `Library/Caches/`, the default `WKWebsiteDataStore`,
or the plugin's own container id map.

This is the first mechanism in this file that would also reach a real user.
Nothing about it needs nine test files in a row: it needs one app that has
been used, and a proxy asked for afterwards. It fits the report the bug
opened with -- "sometimes I have to restart the app for the Tor proxy to
start working" -- except that a restart alone is not enough here, which is
worth saying plainly: in the tier a fresh process with the old container
still fails.

**What this attempt did:** the tier snapshots the accumulated container, then
runs the arm once per candidate subdirectory, each time restoring the
snapshot and deleting only that one -- `Data/Library/Preferences`,
`Data/Library/WebKit`, `Data/Library/HTTPStorages`, `Data/Library/Caches` --
and finally once with the whole container removed as the control. Restoring
the snapshot each time is the point: without it the second trial would be
measuring what the first trial's launch rebuilt. The step also prints the
container's directory tree and size, because the paths above are inferred
from the macOS sandbox layout rather than read off this app.

**Why it was partial:** four candidates and a control, chosen by guessing at
the layout. If none of the four flips it, the listing printed alongside them
says what else is in there.

### Attempt 46 — The bisection was void; its own control said so

**Date:** 2026-09-18
**Commit:** (this one). Run 35316377697 (3104) on `ac610dc`.

```
position=first                          -> proxied proxied proxied
position=glob,  swept=35                -> DIRECT DIRECT DIRECT
wiped-Data-Library-Preferences,  swept=0 -> DIRECT DIRECT DIRECT
wiped-Data-Library-WebKit,       swept=0 -> DIRECT DIRECT DIRECT
wiped-Data-Library-HTTPStorages, swept=0 -> DIRECT DIRECT DIRECT
wiped-Data-Library-Caches,       swept=0 -> DIRECT DIRECT DIRECT
wiped-all,                       swept=0 -> DIRECT DIRECT DIRECT
```

**`wiped-all` is the control and it failed.** On run 3103 the same
`rm -rf "$HOME/Library/Containers/org.codeberg.theoden8.webspace"` followed by
the same arm bound all three shapes. Here it bound none, so nothing after the
loop in this run can be read, and the four subset trials say nothing about
their subdirectories.

The instrument broke it, and the instrument said so in a field that was there
for exactly this: `swept=0` on every trial. Each subset trial restored a
`cp -a` snapshot of the accumulated container before deleting its one path,
so the trials that kept both the preferences and the stores should have found
the 35 containers again and reported `swept=35`. They found none. The restore
silently did nothing -- and its stderr was routed to `/dev/null` by the same
commit that depended on it, which is the second time in this file an
instrument has been built with its own failure mode hidden. Copying a live
macOS sandbox container is evidently not a restore, and it left the container
in a state the following `rm -rf` did not recover from.

Useful anyway: the layout dump printed what is actually under the container.

```
Data/Library/Preferences
Data/Library/WebKit/{WebsiteDataStore,WebsiteData}
Data/Library/Caches/{WebKit,flutter_engine,Tor}
Data/Documents/{html_imports,html_cache,block_stats,webview_state,localcdn_cache}
Data/Library/{Application Support,Saved Application State,Application Scripts,Images,Logs}
Data/tmp/WebKit/{MediaCache,JavaScriptCoreDebug,ModelElement}
```

There is no `Data/Library/HTTPStorages`, so that trial deleted nothing and was
never a test of anything.

**What this attempt did:** dropped the snapshot entirely. The trials now
remove strictly more each time -- `Data/Library/Caches`, then
`Data/Library/WebKit`, then `Data/Library/Preferences`, then `Data/Documents`,
then the whole container -- so the first one that binds names the path that
was carrying it, and the full wipe stays last as the control that must bind.
No copying, nothing suppressed: the `find` and `du` run without
`2>/dev/null`, so a path that does not exist shows up as an error rather than
as a silent pass.

**Why it was partial:** it is the same measurement as attempt 45, retried with
an instrument that can fail loudly. The monotone ordering also means a carrier
that a single app launch rebuilds fast enough would be missed -- though run
3103's `position=first` argues against that, since one launch's worth of state
binds fine.

### Attempt 47 — The position effect is refuted, and so is the disk-state one

**Date:** 2026-09-18
**Commit:** (this one). Run 35322823210 (3105) on `b350d28`.

```
position=first,                    swept=0  -> proxied proxied proxied
position=glob,                     swept=30 -> proxied proxied proxied
cleared-Data-Library-Caches,       swept=0  -> DIRECT DIRECT DIRECT
cleared-Data-Library-WebKit,       swept=0  -> DIRECT DIRECT DIRECT
cleared-Data-Library-Preferences,  swept=0  -> DIRECT DIRECT DIRECT
cleared-Data-Documents,            swept=3  -> DIRECT DIRECT DIRECT
cleared-all,                       swept=0  -> DIRECT DIRECT DIRECT
```

**The glob position bound this time.** Runs 3101, 3102, 3103 and 3104 all
read it direct; here it reads proxied, with `proxy_shape_test.dart`
byte-identical across all five. So "the first proxy file binds and the rest
do not" is not a rule either -- it was four draws that happened to agree, and
the fifth disagreed.

**And `cleared-all` failed again**, as it did on run 3104. A full
`rm -rf` of the sandbox container followed by the arm bound all three shapes
once, on run 3103, and has gone direct on both runs since. So attempt 45's
conclusion -- that the carrier is app-owned disk state, because removing the
container restores binding -- rests on a single observation that has not
reproduced. **It is withdrawn**, along with the reasoning built on it: that
position, elapsed time and prior-launch count were excluded. They were
excluded by that one draw and nothing else.

That is the third time in this file a conclusion has been drawn from a small
number of agreeing draws and refuted by the next run (attempt 38 → 40,
attempt 43 → 45, attempt 45 → here), and the pattern is the finding: **at the
app-process level, whether a per-site proxy binds is a random variable, and
no condition anyone has varied has moved it reliably.**

What is left standing, because it has repeated every time it was measured:
`proxy_binding`'s `pair`, `raw-first` and `sameturn-loadurl` bind in every
run. Nothing else does reliably.

**What this attempt did:** stopped varying conditions. The tier now runs the
same arm eight times back to back with nothing between the launches -- no
wiping, no snapshots, no reordering -- and the verdicts are labelled
`rep-1` through `rep-8`. One fixed condition, eight app launches, a count.
Anything strictly between zero and eight is a race, and says that every
single-draw comparison in attempts 42 through 46 was measuring noise. Zero or
eight would make the condition worth bisecting again, and would be the first
repeated result this line of work has produced.

**Why it was partial:** it measures the noise rather than the mechanism, and
it does so on CI hardware whose behaviour may not be the user's. But no
mechanism can be read off single draws of a variable that moves on its own,
which is what the last six attempts have been doing.

### Attempt 48 — A rate at last, and it points at this investigation's own code

**Date:** 2026-09-18
**Commit:** (this one). Run 35329793142 (3106) on `c7a9b4c`.

Eight launches of one arm, back to back, nothing touched between them:

```
position=first, swept=0  -> proxied proxied proxied
position=glob,  swept=35 -> DIRECT DIRECT DIRECT
rep-1,          swept=0  -> proxied proxied proxied
rep-2,          swept=3  -> DIRECT DIRECT DIRECT
rep-3,          swept=3  -> DIRECT DIRECT DIRECT
rep-4,          swept=3  -> DIRECT DIRECT DIRECT
rep-5,          swept=3  -> DIRECT DIRECT DIRECT
rep-6,          swept=3  -> DIRECT DIRECT DIRECT
rep-7,          swept=3  -> DIRECT DIRECT DIRECT
rep-8,          swept=3  -> DIRECT DIRECT DIRECT
```

**One of eight.** But the eight were not identical, and the field that says
so was already in the verdict: `rep-1` found no stored containers to delete,
and `rep-2` through `rep-8` each found and deleted three -- the three the
previous launch had created. Among the seven genuinely identical launches the
answer was perfectly consistent: nought of seven. So this is not per-launch
randomness after all. Something separates rep-1 from the rest, and the only
thing that does is whether the process deleted data stores before creating
its own.

**That candidate is code this investigation added.** The sweep went in at
attempt 44, to test whether stored containers were the carry-over; it calls
`WKWebsiteDataStore.remove(forIdentifier:)` for each stale id before the arm
creates any store. So the instrument may have been the treatment. Checking
the whole dataset against it: every `swept=0` launch that bound
(`position=first` in five runs, `wiped` on 3103, `rep-1` here) had no delete
call, and every `swept>0` launch went direct -- with **one counterexample**,
run 3105's glob position, which reported `swept=30` and bound all three. One
counterexample in a dataset this noisy is not a refutation, but it is the
reason this entry proposes nothing and measures instead.

It would also re-explain the earlier flips without any of the mechanisms this
file has withdrawn. `position=first` sweeps nothing because the tier has not
run yet. The post-loop `wiped` and `cleared-*` trials sweep nothing because
the container was just deleted -- and those went direct, which is the
awkward half, unless deleting the container from the shell and deleting
stores through the API differ.

**What this attempt did:** made the sweep a knob (`WEBSPACE_SHAPE_SWEEP=0`
skips `listContainers` and `deleteContainer` entirely) and gave every process
its own container ids, so a sweep-off launch creates fresh stores instead of
reusing the previous launch's. The tier runs eight launches alternating
sweep-on and sweep-off, so ordering cannot stand in for the knob. Four of
each, one count per mode.

**Why it was partial:** it tests one candidate, and that candidate has a
counterexample already in the data. If sweep-off binds four of four and
sweep-on nought of four, the effect is the delete call and the next question
is why it poisons the process. If both modes agree, the sweep is innocent and
`rep-1` differed for a reason still unnamed.

### Attempt 49 — The sweep is innocent; the batch position reproduces

**Date:** 2026-09-18
**Commit:** (this one). Run 35338516240 (3108) on `58eb57c`.

Eight launches alternating the sweep knob:

```
position=first,  sweep=on,  swept=0  -> proxied proxied proxied
position=glob,   sweep=on,  swept=35 -> DIRECT DIRECT DIRECT
rep1-on,         sweep=on,  swept=0  -> proxied proxied proxied
rep1-off,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
rep2-on,         sweep=on,  swept=6  -> DIRECT DIRECT DIRECT
rep2-off,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
rep3-on,         sweep=on,  swept=6  -> DIRECT DIRECT DIRECT
rep3-off,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
rep4-on,         sweep=on,  swept=6  -> DIRECT DIRECT DIRECT
rep4-off,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
```

**Sweep off bound nought of four.** Attempt 48's candidate -- that calling
`WKWebsiteDataStore.remove(forIdentifier:)` before creating a store poisons
the process -- is refuted. Turning the call off does not restore binding, and
`swept=-1` confirms the knob took effect. The instrument this investigation
added in attempt 44 is not the treatment.

**What did reproduce, exactly, is the batch position.** Run 3106: the first
of eight launches bound, the other seven did not. Run 3108: the first of
eight bound, the other seven did not. Two runs, same shape, and in 3108 the
knob was alternating underneath it, so the pattern is indifferent to the
sweep.

The launch timestamps say what separates them, and it is not much:

```
12:21:31  webspace_site_membership_test.dart   (loop's last file, ~110s)
12:23:41  rep1-on    -> proxied     ~20s idle since the previous app exited
12:24:23  rep1-off   -> DIRECT      ~7s idle
12:25:04  rep2-on    -> DIRECT      ~7s idle
...       every later launch ~40-60s apart, ~7s idle
```

Two candidates fit: the length of the idle gap before the app starts, or the
identity of the process that ran before it (a different test file versus
`proxy_shape` itself). `position=first` fits both -- it follows the Tor
scenario, a different file, after a step boundary.

**What this attempt did:** varied the gap and nothing else. Three lengths --
0, 45 and 180 seconds of idle before launch -- two draws each, alternating so
drift through the batch cannot stand in for the gap, with the sweep off
throughout since it is not the variable. If a long enough gap binds, the
mechanism is something the previous process holds and releases on a timer,
and the next question is what. If no gap binds, the gap is out and the
preceding file's identity is the remaining candidate.

**Why it was partial:** two draws per gap is thin, and this file's history is
mostly conclusions drawn from few draws. The reading to trust is a gap that
binds twice while zero binds neither, or the reverse; one of each says only
that the noise is back.

### Attempt 50 — The idle gap is out, and the batch-position reading with it

**Date:** 2026-09-18
**Commit:** (this one). Run 35345472065 (3109) on `fe0f719`.

```
position=first, sweep=on,  swept=0  -> proxied proxied proxied
position=glob,  sweep=on,  swept=35 -> DIRECT DIRECT DIRECT
gap0-a,         sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
gap45-a,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
gap180-a,       sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
gap0-b,         sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
gap45-b,        sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
gap180-b,       sweep=off, swept=-1 -> DIRECT DIRECT DIRECT
```

**Nought of six.** Three minutes of idle before launch binds nothing, so the
candidate attempt 49 raised -- something the previous process holds and
releases on a timer -- is refuted.

**It also refutes attempt 49's other half.** "The batch's first launch binds
and no later one does" held across runs 3106 and 3108; here the batch's first
launch (`gap0-a`) went direct like the rest. The difference is that in this
run every batch launch had the sweep **off**, and in the earlier two the
first one had it **on**. So batch position was never the variable either.

**What fits every launch in all three runs.** Every launch that bound had
listed the stored containers and found **none** (`sweep=on, swept=0`); every
launch that did not had either skipped the listing (`sweep=off`) or listed
and found some (`swept>0`). That covers `position=first` in three runs,
`rep-1` on 3106, `rep1-on` on 3108, and all eighteen negatives. One
counterexample stands: run 3105's glob position listed 30 and bound.

This is a correlation, not a mechanism, and it is confounded twice over --
`swept=0` means both "the process enumerated the stores" and "there were none
to find", and the sweep also deletes what it finds. Attempt 44 already showed
that deleting 35 stores does not restore binding, which separates deleting
from the rest; what is left to separate is enumerating from the state.

**What this attempt did:** split the knob three ways. `on` lists and deletes,
`list` lists and deletes nothing, `off` does neither. The listing is a single
channel round trip into `WKWebsiteDataStore.fetchAllDataStoreIdentifiers`, so
if `list` binds like `on` the enumeration is what matters -- which would be a
concrete WebKit-level statement: asking for the data store identifiers before
creating a store changes whether that store's proxy applies. If only `on`
binds, the empty state does. If neither, the earlier binds were something
else again. Three modes, two draws each, alternating.

**Why it was partial:** two draws per mode, and a correlation assembled after
the fact from runs that varied other things. The reading to trust is a mode
that binds twice while another binds neither.

### Attempt 51 — It is the container count the process starts with

**Date:** 2026-09-18
**Commit:** (this one). Run 35354557619 (3110) on `413b8de`.

```
position=first  sweep=on    swept=0   -> proxied proxied proxied
position=glob   sweep=on    swept=35  -> DIRECT DIRECT DIRECT
on-a            sweep=on    swept=0   -> proxied proxied proxied
list-a          sweep=list  swept=3   -> DIRECT DIRECT DIRECT
off-a           sweep=off   swept=-1  -> DIRECT DIRECT DIRECT
on-b            sweep=on    swept=9   -> DIRECT DIRECT DIRECT
list-b          sweep=list  swept=3   -> DIRECT DIRECT DIRECT
off-b           sweep=off   swept=-1  -> DIRECT DIRECT DIRECT
```

Listing is not it and deleting is not it: `list` went direct twice, `on-b`
deleted all nine it found and went direct, and `off` went direct without
touching the registry at all. What separates the two launches that bound from
the six that did not is the number they started with. **Zero binds; anything
above zero does not, and deleting them at startup does not undo it.**

The same rule fits every launch in the two runs before it -- run 3106's
`rep-1` (0, bound) against `rep-2..8` (3 each, none bound), run 3108's
`rep1-on` (0, bound) against the rest -- and `position=first` in five
consecutive runs, which by construction starts before any proxy file has run.
That is 24 launches with one rule and one counterexample: run 3105's glob
position listed 30 and bound.

**This is the shape attempt 43 and attempt 45 were circling and attempt 44
mis-eliminated.** Attempt 44 deleted all 35 stored containers at startup, saw
no change, and concluded the containers were not the carrier. The deletion was
real and the conclusion was wrong in a specific way: deleting them inside the
process is too late. The process has already started with them present.

**Why it matters beyond the tier.** If it holds, a WebSpace process binds a
per-site proxy only when no per-site container exists on disk when it
launches -- which for a user means the feature works on a fresh install and
stops working once any site has ever been opened. That is a much larger claim
than anything in this file so far, and it is exactly why the next run tests
it rather than this one asserting it.

**What this attempt did:** added a `purge` mode that deletes every stored
container and mounts nothing, so the clearing happens in a *previous*
process. Each pair is then a probe that starts with none and a second probe
that starts with the three the first made, both with the sweep off so nothing
inside the process touches the registry. Two pairs. First of each pair binds
and second does not means the rule holds and the variable is the state at
launch.

**Why it was partial:** it is still a correlation over one tier's hardware,
the counterexample from run 3105 is unexplained, and nothing here says *why*
an existing store stops a new store's proxy from applying. That question is
for WebKit's source once the rule survives its own test.

### Attempt 52 — The container count is refuted, and the first source-level lead

**Date:** 2026-09-18
**Commit:** (this one). Run 35362259792 (3111) on `16b7bef`.

```
position=first  sweep=on     swept=0   -> proxied proxied proxied
position=glob   sweep=on     swept=35  -> DIRECT DIRECT DIRECT
purge-a         sweep=purge  swept=0   -> (mounted nothing)
probe1-a        sweep=off    swept=-1  -> proxied proxied proxied
probe2-a        sweep=off    swept=-1  -> DIRECT DIRECT DIRECT
purge-b         sweep=purge  swept=6   -> (mounted nothing)
probe1-b        sweep=off    swept=-1  -> DIRECT DIRECT DIRECT
probe2-b        sweep=off    swept=-1  -> DIRECT DIRECT DIRECT
```

The two pairs disagree. `probe1-a` and `probe1-b` are the same launch under
the same knobs after the same purge, and one bound while the other did not.
**The rule of attempt 51 is refuted.** Zero stored containers at launch is not
sufficient, so it is not the carrier either.

One loose end, and it does not save the rule. The purge stage does not verify
its own work: it deletes and reports a count, and nothing re-lists afterwards,
so `probe1-b` starting at zero is inferred rather than measured. The inference
is strong -- `glob` deleted 35 in-process and `purge-a`, the next launch,
found none, so a delete does reach disk across processes -- but `purge-b`
differs from `purge-a` in exactly one way: it had six to delete and `purge-a`
had none. A residue of deletion, rather than a residue of existence, is the
only reading the data still permits, and it is a different claim from the one
being tested.

**What this attempt did:** added a `purge` mode that deletes every stored
container and mounts nothing, so the clearing happens in a *previous* process,
then ran two purge/probe/probe rounds. It was a clean test and it returned a
clean negative.

**The first source-level evidence in this file.** Everything above attempt 52
is behaviour measured through the tier. Reading WebKit's own source (main,
`Source/WebKit`) gives a mechanism that no black-box run would have found:

- `WKWebsiteDataStore.mm:561` -- assigning `nil` or `[]` to
  `proxyConfigurations` is not "no proxy for this store". It calls
  `clearProxyConfigData()`, which reaches
  `NetworkSessionCocoa::clearProxyConfigData()` (`NetworkSessionCocoa.mm:2061`)
  and calls `nw_context_clear_proxies()` on the `nw_context_t` of every live
  session. `setProxyConfigData` (`:2080`) does the same clear before adding.
- The pinned fork assigns `[]` in two places: `ProxyManager.releasePerSiteProxy`
  (`activeProxyConfigurations ?? []`) and `clearProxyOverride()` ->
  `fanOutToFollowingStores([])`, which walks the default store, a fresh
  non-persistent store, **and every cached container store**.
- Whether one `nw_context_t` is shared across data stores is not answerable
  from WebKit's source: `_networkContext` is CFNetwork SPI. WebKit collects
  the contexts into an `NSMutableSet` before clearing, which is what deduping
  a shared object looks like, but a single `NetworkSessionCocoa` owns several
  session wrappers and that alone explains the set.
- `NetworkProcessCocoa.mm:307` -- `setProxyConfigData` returns silently when
  the session does not exist yet. The UI process caches the value and re-sends
  it through `NetworkSessionCreationParameters` (`WebsiteDataStore.cpp:2348`),
  so the early path is covered, but only through that one channel.
- `Tools/TestWebKitAPI/Tests/WebKit/WKWebView/Proxy.mm` and
  `WebsiteDataStoreCustomPaths.mm`: every upstream `proxyConfigurations` test
  uses **one** data store, mostly the default one. There is no upstream test
  anywhere with two identified data stores carrying different proxies at once.
  The configuration this bug is about is untested in WebKit.
- Apple's documentation for the property is the WebKit header
  (`WKWebsiteDataStore.h`); the developer.apple.com page 404s. It says only
  that changing the configurations may interrupt current networking, "so it is
  encouraged to finish setting the proxy configurations before starting any
  page loads".

**Why it was partial:** the refutation is solid but names no cause, and the
source findings are unmeasured -- nothing yet shows an empty assignment
actually happening between a per-site set and a load, and nothing shows the
context is shared. The next instrument is a trace on every
`proxyConfigurations` assignment (store identity, count, caller), which turns
the WebKit reading into an observation instead of a hypothesis. The purge
stage should also re-list after deleting, so a probe's starting state is
measured rather than inferred.

### Attempt 53 — The plugin is exonerated; the divergence is inside WebKit

**Date:** 2026-09-18
**Commit:** (this one). Run 35370986685 (3112) on `27f07d3`.

Every write to `WKWebsiteDataStore.proxyConfigurations` now goes through one
traced choke point. Across the **whole** macOS integration tier:

```
57 assignments, every one of them:  reason=per-site  count=1  pinned=false
 0 assignments with count=0
 0 assignments with reason=fanout-default / fanout-ephemeral / fanout-container
 0 assignments with reason=replay or reason=release
```

```
position=first  started=0  -> 3x per-site count=1 -> proxied proxied proxied
position=glob   started=35 -> 3x per-site count=1 -> DIRECT DIRECT DIRECT
purge-a         started=0   swept=0  left=0
probe1-a        started=0  -> 3x per-site count=1 -> DIRECT DIRECT DIRECT
probe2-a        started=3  -> 3x per-site count=1 -> DIRECT DIRECT DIRECT
purge-b         started=6   swept=6  left=0
probe1-b        started=0  -> 3x per-site count=1 -> DIRECT DIRECT DIRECT
probe2-b        started=3  -> 3x per-site count=1 -> DIRECT DIRECT DIRECT
```

**The clearing hypothesis from attempt 52 is dead.** An empty array is never
assigned in this tier, so `clearProxyConfigData` and `nw_context_clear_proxies`
are never reached. The process-wide fan-out never runs either: no test here
sets a global override, so `setProxyOverride`, `applyActiveProxyOverride` and
`releasePerSiteProxy` contribute nothing. WebKit's source reading was correct
about what an empty assignment does and irrelevant to what is happening here.

**What is left is sharper than anything before it.** The launch that binds and
the launches that do not are *identical at the seam*: one store, one
assignment, one config, same reason, same count, same order, same code path.
Whatever decides the outcome is downstream of
`store.proxyConfigurations = [config]` -- inside WebKit, not in the plugin and
not in the app. Fifty-two attempts of black-box bisection were searching a
space the answer is not in.

**Attempt 52's refutation is now measured rather than inferred.** `started=`
reports the stored-container count on every launch and a purge reports what it
left. `probe1-a` and `probe1-b` both started at **0** and both went direct,
while `position=first` also started at 0 and bound. The purges verified
themselves (`swept=6 left=0`). The count a process starts with is not the
variable, and this time nothing about it is an inference.

**The one durable positive, six runs running:** `position=first` -- the
proxy_shape launch that runs ahead of every other integration file -- binds
every time. In run 3111 `probe1-a` bound too; in 3112 it did not. Nothing
else binds twice.

**Not a regression from the instrumentation:** the Tor scenario failed in this
run with `Tor did not finish bootstrapping in time. tag=loading_descriptors
at=60%`, an external bootstrap timeout on the runner. It is not the trace
write, which was the first suspect because it happens inside
`getOrCreateDataStore` under `sharedStoresLock`.

**Why it was partial:** it says where the mechanism is *not*. The next
instrument has to read WebKit's own answer rather than the plugin's intent:
read `configuration.websiteDataStore.proxyConfigurations?.count` back
immediately after the WebView is constructed and again when the navigation
starts, and compare the store identity the WebView ends up holding against the
one that was assigned. Three outcomes, all informative -- the readback is
empty (something reset it), the readback is 1 and the traffic is still direct
(WebKit is declining to use it), or the identity differs (the WebView is not
on the store that was configured).

### Attempt 54 — WebKit holds the proxy and does not use it

**Date:** 2026-09-18
**Commit:** (this one). Run 35390136913 (3118) on `f43cda2`, fork `f34ba3c3`.

The WebView is now asked what its store's proxy is, twice: right after
construction and when a load starts.

```
launch      result    assigned  same store   same store   count
                                at prepare   at navstart
first       proxied   3         3            -            1
glob        DIRECT    3         3            3            1
probe1-a    DIRECT    3         3            3            1
probe2-a    DIRECT    3         3            3            1
probe1-b    DIRECT    3         3            3            1
probe2-b    DIRECT    3         3            3            1
```

**In every launch that went direct, all three WebViews are on exactly the
store that was configured, and that store still reports one proxy
configuration when the navigation starts.** The store identity matches the
`proxy-assign` line's, at both points, every time. Nothing is reset, nothing
is swapped.

The instrument is not reading a constant: `ws-proxy-binding-control`, the
WebView built with `proxySettings=false`, reads `count=0` at both points in
the same run. Zero and one are both reachable; the proxied sites report one.

`position=first` has no `at=navstart` line because the trace file is read at
`tearDownAll` and a proxied load has not started one by then. That is the
dump's timing, not a difference in behaviour -- its `at=prepare` readback is
identical to every other launch's.

**This is the end of what the UI process can be asked.** The app sends the
proxy, the plugin assigns it once and never clears it (attempt 53), the
WebView holds the store it was given, and that store's public API reports the
configuration intact at the moment the load begins. The traffic goes direct
anyway. Whatever drops it is below `WKWebsiteDataStore.proxyConfigurations`,
in the network process, where nothing in this repository can observe it.

**What follows from that:**

- The remaining work is not bisection in this repo. It is a minimal repro
  against WebKit: one `WKWebsiteDataStore(forIdentifier:)`, one
  `nw_proxy_config_create_socksv5`, one load, in a loop across process
  launches -- and a bug report. Attempt 53 already established there is no
  upstream test with two identified data stores carrying different proxies;
  this shows that even *one* identified store is unreliable.
- `_WKWebsiteDataStoreConfiguration.proxyConfiguration` (the CFNetwork
  `connectionProxyDictionary` path, which WebKit's own `TEST(WebKit, SOCKS5)`
  exercises per data store) is the control that would separate "the
  `nw_proxy_config` path is broken" from "per-store proxying is broken". It is
  SPI, so it can answer the question and cannot ship.
- One in-repo fact still has no explanation and is now sharper for it:
  `position=first` binds in seven consecutive runs and no other launch binds
  twice. Since the plugin's behaviour and the store's state are now measured
  identical between the two, whatever separates them is process-level and
  outside the data store.

**Why it was partial:** it locates the defect without naming its mechanism,
and the mechanism sits in code this project does not build. The next artefact
is a repro and a bug report, not another instrument.

### Attempt 55 — A bare WKWebView does not proxy, and the tier's roles swapped

**Date:** 2026-09-19
**Commit:** (this one). Run 35409929833 (3121) on `e23458e`.

A native probe with none of the app in it -- one `WKWebsiteDataStore`, one
`nw_proxy_config_create_socksv5`, one bare `WKWebView`, one load, no plugin,
no container registry, no settings parser, no Flutter webview widget -- run
in both tier positions, in two store shapes:

```
proxy_probe  first  nonPersistent -> DIRECT   (ok=true configured=1 detail=didFinish)
proxy_probe  first  identified    -> DIRECT   (ok=true configured=1 detail=didFinish)
proxy_probe  glob   nonPersistent -> DIRECT
proxy_probe  glob   identified    -> DIRECT
```

`configured=1` is read back off the store, so the configuration is present;
`didFinish` says the load succeeded, over the direct route. The
non-persistent shape is the one WebKit's own `TEST(WebKit, SOCKS5API)`
proxies upstream, and it does not proxy here.

**But the same run inverts what that would otherwise mean.** In the same
tier, on the same runner:

```
proxy_shape  first  -> proxied proxied proxied
proxy_shape  glob   -> proxied proxied proxied   (started=35)
proxy_binding       -> pair=0 of 2, stair all DIRECT
proxy_connect_https, proxy_http_connect, proxy_rate,
proxy_relay, proxy_simultaneous, proxy_window -> DIRECT
```

Two things here have never happened before. `proxy_shape` proxied in its
**glob** position, which has gone direct in every previous run, and with 35
stored containers at launch. And `proxy_binding`, the one file that proxied
reliably from attempt 40 onward, went direct in every arm. The two swapped
roles.

**So the honest reading is narrower than the probe's result looks.** A bare
WKWebView went direct twice, which does rule out the app's machinery as the
*cause* -- nothing the plugin does is required to fail. It does not
establish that WebKit always fails, because six app-built webviews proxied
in the same run. And a tier whose two proxy files can trade places between
runs is not yet a tier whose single readings mean anything, which is the
error that voided attempts 40 through 53.

**What this attempt actually settles:** the probe exists, runs, reads its own
store back, and reports. It is now an instrument that can be pointed at the
question rather than a hypothesis about it.

**Why it was partial:** the probe and the app's webviews ran in *separate
processes*, so a split between them can still be process-to-process variation
rather than a difference between the two shapes. The next attempt removes
that: the bare probe now runs inside `proxy_shape`'s own process, in the same
frame, against the same SOCKS endpoint, so one verdict line carries three
app-built webviews and one bare one. A split there cannot be tier position,
container state or machine.

**Not this PR's, noted once:** `page_zoom_test.dart` appeared in the failing
set with `(setUpAll) (failed after test completion)`, the uncaught
async-error-on-a-fixture-socket shape the fixtures already document. One
occurrence, unrelated to the proxy path.

### Attempt 56 — The split, in one process: the app's WebViews proxy, a bare one does not

**Date:** 2026-09-19
**Commit:** (this one). Run 35417469455 (3123) on `27c51aa`.

The bare `WKWebView` now runs inside `proxy_shape`'s own process, in the same
frame, against the same SOCKS endpoint as the three app-built WebViews.

```
position=first  started=0
  raw-initial->proxied  factory->proxied  raw-loadurl->proxied  bare-wkwebview->DIRECT

position=glob   started=35
  raw-initial->DIRECT   factory->DIRECT   raw-loadurl->DIRECT   bare-wkwebview->DIRECT
```

**The first line is the result.** Three WebViews the app built proxied while
a bare one went direct, in the same process, the same frame and the same
endpoint. That split cannot be tier position, container state or machine --
the three confounds that voided every reading from attempt 40 to attempt 53.
`configured=1` on the bare one, so its store held the configuration and
WebKit did not use it.

**This is the first known-good side this investigation has had.** Everything
until now compared a failing thing to another failing thing, or to itself in
another process. There is now a WebView that proxies and a WebView that does
not, side by side, and the difference between them is a short list of
construction details rather than a hypothesis about Apple.

It also corrects attempt 55's reading. The bare probe going direct there was
not "WebKit is broken outright"; it is one side of a split that only becomes
visible next to a working control.

**What the second line means and does not mean.** In the glob position
everything went direct, the bare arm included. That is the tier's usual
state and says nothing on its own -- it is the first line that carries the
information. Attempt 55 already showed the two positions can trade places
between runs, so neither line is a claim about position.

**What this attempt did:** moved the probe into the arm that had a positive
control, which is the whole of it. Everything else was already built.

**Why it was partial:** it names *that* the construction differs without
naming *which* difference. The bare arm differs from the app's WebViews in at
least three ways at once, so the next attempt splits it into arms that each
differ in exactly one: `bare` (unchanged), `bare-ident` (the identified store
shape the app's containers use, rather than a non-persistent one), and
`bare-window` (added to the app's window, as a real platform view is). The
first of those to proxy names the variable.

### Attempt 57 — Not the store shape, not the view hierarchy, and my own arms were confounded

**Date:** 2026-09-19
**Commit:** (this one). Run 35420716772 (3124) on `29f01e3`.

Three arms, each one variable away from attempt 56's bare baseline:

```
position=first  started=0
  raw-initial->proxied  factory->proxied  raw-loadurl->proxied
  bare->DIRECT  bare-ident->DIRECT  bare-window->DIRECT

position=glob   started=35
  everything DIRECT
```

All three bare arms reported `ok=true configured=1 detail=didFinish`.

**The split reproduced, which is the first thing worth saying.** Attempt 56's
result was one run; this is a second, independently. Three app-built WebViews
proxy and bare ones do not, in one process, one frame, one endpoint.

**Neither candidate is the variable.** `bare-ident` used
`WKWebsiteDataStore(forIdentifier:)`, the store shape the app's containers
use, and went direct. `bare-window` was added to the app's key window's
content view, and went direct. So the store shape is not it and being in the
view hierarchy is not it.

**And the arms were confounded, by this file's own construction.** All three
ran *after* the three app WebViews had already loaded and the frame had
settled. They therefore differ from the app's WebViews in when they ran as
well as in how they were built -- and "the first one binds, later ones do
not" has shadowed this bug since attempt 43, withdrawn but never cleanly
separated inside a single process. Nothing above distinguishes "a bare
WebView cannot proxy" from "the fourth WebView in a process cannot proxy".

That is a defect in the experiment, not in the reading of it, and it is
mine: attempt 56 declared a construction difference on evidence that also
permits an ordering one.

**What this attempt did:** added the two one-variable arms and found both
innocent, then found the confound they share.

**Why it was partial:** it cannot name the variable while order and
construction are still tied together. The next attempt unties them with a
`bare-first` arm that runs *before* the frame is mounted, making it the first
WebView in the process:
  - `bare-first` proxies while the later bare arms do not -> the variable is
    order, and every construction reading here and in attempt 56 is void.
  - `bare-first` goes direct while the app's three proxy -> construction
    survives, and the remaining differences are the plugin's shared
    `WKProcessPool` and the rest of its `WKWebViewConfiguration`.

### Attempt 58 — It is order. Only the first WebView in a process is proxied

**Date:** 2026-09-19
**Commit:** (this one). Run 35424236835 (3125) on `1d0e170`.

```
position=first  started=0
  bare-first->proxied
  raw-initial->DIRECT  factory->DIRECT  raw-loadurl->DIRECT
  bare->DIRECT  bare-ident->DIRECT  bare-window->DIRECT
```

Every arm reported `ok=true configured=1 detail=didFinish`: each store held
exactly one proxy configuration and every load completed.

**This is an intervention, not a correlation.** `bare-first` is a bare
`WKWebView` created before the frame is mounted, so it took the first slot in
the process. The app's three WebViews -- which proxied in runs 3123 and 3124,
when they *were* first -- went direct the moment something else was first.
Nothing about how they are built changed between those runs and this one.
Only their position in the process did, and the outcome followed it.

Within the bare arms alone the same rule holds with construction held
constant: `bare-first` (first) proxied, `bare` (second, identical
construction) went direct, and so did the third and fourth.

**The rule: in a WebKit process, only the first WebView gets its store's
proxy. Every later one loads direct, whatever its store says.**

**This voids the construction readings in attempts 56 and 57.** The split
they measured was real but misattributed: the app's WebViews were not
proxying because of how the plugin builds them, they were proxying because
they were first. Neither the store shape nor the view hierarchy was ever
relevant, and neither was the plugin. Those attempts stand as recorded --
the observations were sound, the conclusion drawn from them was not.

**It also explains the whole file above it.** `position=first` binding in
seven consecutive runs; `proxy_binding`'s `pair=2 of 2` and its later arms
going direct; every "later frame" arm in every proxy file; the tier's
apparent bistability, which was two files competing for one slot. Attempt
43's first-frame rule was right in substance and was withdrawn only because
it was tested across processes, where it could never be seen.

**What it means for the goal.** Two per-site proxies cannot both work on
macOS through `WKWebsiteDataStore.proxyConfigurations`, because the second
site is never first. That is not a bug in this app and no amount of
per-site plumbing fixes it. Two routes follow:

1. A WebKit bug report with a five-line repro: two data stores, two
   `nw_proxy_config_create_socksv5`, two loads, in one process -- only the
   first is proxied.
2. A product path that does not need two: give WebKit one proxy
   configuration pointing at a local relay, and let the relay dispatch
   per-site to Tor, to a SOCKS upstream or direct. `LocalProxyRelay`
   (`lib/services/local_proxy_relay.dart`, nine green tests including
   TLS-through-tunnel) was built for this and has been sitting unwired.

**Why it was partial:** "first" is not yet pinned down. First WebView, first
load, first store handed a proxy, or a window of time -- the run cannot
separate those, because the first arm was all four at once. The next probe
holds construction fixed and varies only what "first" means: create two
stores before either loads, then load them in order; and create one WebView,
let it finish, then create a second. It also does not say whether the first
slot is per-process or per-network-process, which decides whether an app
restart can reclaim it.

### Attempt 59 — Being first is necessary, not sufficient: the same file split by launch

**2026-09-19**, PR #597, run 3125, `1aaf404`.

**What it did.** Read run 3125's *other* launch. Attempt 58 was written from
the `position=first` process and stopped there; the same file, byte-identical,
ran again in its glob position in the same job, and its verdict was different
in the one place that matters:

```
position=first, started=0,  swept=0:
  bare-first->proxied  raw-initial->DIRECT factory->DIRECT raw-loadurl->DIRECT
  bare->DIRECT bare-ident->DIRECT bare-window->DIRECT

position=glob,  started=35, swept=35:
  bare-first->DIRECT   raw-initial->DIRECT factory->DIRECT raw-loadurl->DIRECT
  bare->DIRECT bare-ident->DIRECT bare-window->DIRECT
```

Both `bare-first` arms reported `ok=true configured=1 detail=didFinish`: the
store held exactly one proxy configuration and the load completed. In the
glob-position process the *first* WebView went direct.

`proxy_relay_binding` read the same way and is worth recording, because it is
the only file that tests route 2 of attempt 58: its own plain-SOCKS control
read DIRECT, so its four relay panes reading DIRECT says nothing about the
relay. That process had no working proxy at all.

**Why.** Attempt 58's rule is an ordering rule and an ordering rule cannot
produce two verdicts for the same first WebView. So it is necessary and not
sufficient: something about the *launch* decides whether the first slot works,
and the two launches differed in more than one way at once -- one was the
machine's first app launch, and one swept 35 stored containers before any
WebView existed while the other found nothing to sweep.

Three launches back to back now separate those, each differing from the next
in one thing:

| launch | first app launch | stale containers | sweeps them |
|--------|------------------|------------------|-------------|
| first  | yes              | none             | nothing     |
| second | no               | yes              | no          |
| third  | no               | yes              | yes         |

`second` binds and `third` does not names the sweep. Both bind names the tired
machine, and voids every glob-position reading this tier has produced. Neither
binds names being the machine's first app launch.

In the same commit, three arms ahead of the frame take apart what "first"
means, since attempt 58's arm was the first WebView, the first load and the
first store handed a proxy at once: an unproxied WebView that loads, then a
proxied one, then a proxied one through a *second* SOCKS endpoint -- the first
time one process has been asked for two distinct upstreams, which is what a
Tor site beside a plain-proxy site is.

**Why it was partial.** No result yet; this records the reading that corrects
attempt 58 and the two experiments it forced. It also leaves attempt 58's
conclusion for the goal standing but unproven in the direction that matters:
if the answer is the sweep, or anything else about the launch, then "the
second site is never first" is not the whole constraint and the WebKit bug
report in attempt 58 would describe a repro that does not reproduce. The
`LocalProxyRelay` route is untested for the same reason -- the only run that
exercised it had a dead control.

Two readings this run does not address: whether the slot is per-process or
per-network-process (which decides whether an app restart reclaims it, and is
the one that would explain the original "sometimes I have to restart the app
for Tor"), and `proxy_shape_test.dart`'s own assertion, which asserted the
three app shapes bind and became unsatisfiable the moment a probe started
running ahead of them. It now asserts instrument health -- every arm reached a
terminal outcome -- because the finding is in the verdict line, not in a
threshold.

### Attempt 59b — The slot is spent by the first WebView, proxy or no proxy

**2026-09-19**, PR #597, run 3127, `313d3d9`.

**What it did.** Ran the three arms ahead of the frame. Every arm in every
launch went direct:

```
position=first,  sweep=on,  started=0, swept=0:
  first-noproxy->DIRECT (configured=0) second-proxy-A->DIRECT (configured=1)
  third-proxy-B->DIRECT (configured=1) ... all nine DIRECT
position=second, sweep=off, started=3:   all nine DIRECT
position=third,  sweep=on,  started=6, swept=6: all nine DIRECT
```

Every proxied arm reported `configured=1 detail=didFinish`: the store held one
proxy configuration and the load completed.

**Why this is the answer and not another null run.** Run 3127's first launch
matched run 3125's first launch in every condition the file records --
`position=first`, `started=0`, `swept=0`, same job, same runner image -- and
differed in exactly one thing: its first WebView carried no proxy.
`bare-first` in 3125 was a non-persistent store + a SOCKS5 configuration + a
load, and it proxied. `second-proxy-A` in 3127 is the same three things, one
place later, and it went direct. The only edit between them is that an
unproxied WebView loaded first.

**So the process's proxy slot is claimed by the first WebView regardless of
what it carries, and an unproxied first load spends it.** That is the shape of
the original report: *"sometimes I have to restart the app for tor proxy to
start working."* A session whose first site is unproxied has no proxy for any
site, and a restart that happens to load the Tor site first works. It also
means attempt 58's "the second site is never first" understates it -- the
*first* site is not reliably first either, because anything the app loads
before it takes the slot.

**Why it was partial.** Two things.

1. **The launch-level effect is untouched, and I confounded it.** Attempt 59
   put the burn arms and the sweep bisection in the same file, and the burn
   arm runs first, so all three launches went direct for the same reason and
   said nothing about the sweep, the stale containers or being the machine's
   first app launch. Run 3125's glob position went direct on a *proxied*
   first arm, which no ordering rule explains; that is still open.
2. **Nothing here had a positive control, and that is why one run of nine
   DIRECT arms took a second run to read.** A launch with no working slot and
   a launch whose slot was spent produce identical logs. The first arm is now
   a knob (`WEBSPACE_SHAPE_FIRSTARM`), and the launches run
   `proxied / noproxy / proxied`: launches 1 and 3 must bind or the run is
   void, 1 vs 3 isolates the launch effect with the first arm fixed, and 2 vs
   3 isolates the burn with the launch fixed.

Still unaddressed: whether the slot is per-process or per-network-process,
which decides whether an app restart reclaims it.

## Known open gaps

0. **A store with no container cannot be given a proxy after its first load.**
   `WKWebsiteDataStore.default()` is a process singleton; attempt 8 rebuilds a
   container's store to get a clean one, and there is no equivalent for the
   default store. Every proxied site in the app has a container (the two share
   an iOS 17 / macOS 14 floor), so the path is unreachable today — but a future
   caller that skips `siteOwnsContainerProfile` would leak silently.
1. **No general guard on the seam.** The plugin's settings parser fails open by
   construction: an unrepresentable or misnamed field is a no-op. Nothing
   compares the map Dart sends against the properties the native side actually
   set. `getRealSettings` exists and could answer that for a live WebView.
2. **The Apple tiers are the only place the effect is observable**, and until
   2026-09-15 the macOS integration tier had never completed a run (BUG-013,
   gap 1). Both instances here were reported from a user's device first.
3. **Reach is wider than the proxy.** The same parser carries the container id,
   the UA, the media gates and every other per-site field. Only the proxy has an
   effect-level test.
4. **WITHDRAWN in attempt 43, and the replacement withdrawn in attempt 47.**
   The frame rule went first: one file run twice in one run bound a proxy
   ahead of the other integration files and bound none in its alphabetical
   place. Then the position rule went too -- run 3105 read that same
   alphabetical position as proxied, and the container wipe that had restored
   binding once failed on the two runs after it. What survives is that
   binding is a random variable at the app-process level with no condition
   yet shown to move it. Everything below was measured one draw at a time and
   has to be taken again. Kept for lineage, not as a statement of behaviour.

   ~~**On Apple, a load is proxied only if the webview issues it as it is
   constructed and that webview is constructed in the process's first frame
   (BUG-014 attempt 32, measured with no app code on the webview), so the
   per-site proxy leaks on everything a user does after a site's landing
   page.**~~ Narrowed in attempt 38: **simultaneity is not part of this.** Four stores
   on three distinct SOCKS5 upstreams, all built in the first frame, each
   reached its own and none crossed. The constraint is the frame alone. **Retracted in attempt 40:** that was one draw. The same
   file, byte-identical, read all four DIRECT on the next run, and in that
   run a different process proxied its first-frame pair. Simultaneity is
   not established either way, and the first frame is not a reliable
   boundary -- only a more likely one.
   Settled along the way: it is not a race and not elapsed time (five
   consecutive navigations, all direct, the first at 0 ms), not the load
   mechanism, and not a process-wide proxy the newest store overwrites.
   Superseded: attempt 29's "only the first load a webview issues" and attempt
   31's "only a load in the first frame". The open question is what closes the
   window, and attempt 33 narrowed it by elimination rather than by adding a
   candidate: WebKit's proxy path, read end to end, has no such window in it —
   a store keeps its proxy for every load on its session, and the one call that
   takes a proxy off a live store (an empty `proxyConfigurations`) is on none
   of these paths. `proxy_window_test.dart` still separates the widget frame
   from the first network activity, but the network-process mechanism attempt
   32 proposed for it is refuted, so neither branch has one behind it now. The app still presents the feature as working. Until it
   fails closed, a user who pins a site to Tor or to a proxy gets one proxied
   page and the device IP thereafter. Superseded detail, kept for lineage:
   the earlier reading was that a WebView built after the first frame cannot be
   proxied. Settled in attempt 22 across three arrangements. Nothing done to
   the data store beforehand changes it, and no public API reopens the window.
   So a site opened later in a session, a site whose proxy the user changes, an
   archive unlocked mid-session and a Tor site whose SOCKS port arrives after
   bootstrap all miss it. Each currently loads over the device IP rather than
   failing closed, which is the more urgent half: a leak is worse than a
   feature that does not work. Follow-ups tracked here: build every proxied
   site's WebView in the first frame, fail closed for the ones that cannot,
   and pin Tor's SOCKS port at startup so Tor sites can make that frame.
5. **An effect-level test can be unfalsifiable and look green.** Both of attempt
   3's scenarios asserted "the origin was not reached", which any failure to load
   satisfies — and one of them could not have reached it under any binding
   (loopback), while the other never issued the load at all (widget reuse). The
   structural gate added in attempt 4 covers those two specific shapes; the
   general rule — an effect-level assertion needs a control that fails when the
   instrument is broken — is not enforced anywhere. The sibling shape — a test that
   **skips** and is counted as a run — has now happened four times (attempts
   35, 37 and twice in 38). Each was gated afterwards by name: the
   `PlatformInfo.initialize()` rule, the floor-assert rule, and the
   no-`openssl` rule. Nothing gates the class.
