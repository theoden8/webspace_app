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
4. **An effect-level test can be unfalsifiable and look green.** Both of attempt
   3's scenarios asserted "the origin was not reached", which any failure to load
   satisfies — and one of them could not have reached it under any binding
   (loopback), while the other never issued the load at all (widget reuse). The
   structural gate added in attempt 4 covers those two specific shapes; the
   general rule — an effect-level assertion needs a control that fails when the
   instrument is broken — is not enforced anywhere.
