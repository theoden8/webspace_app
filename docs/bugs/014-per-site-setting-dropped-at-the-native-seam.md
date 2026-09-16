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


## Known open gaps

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
