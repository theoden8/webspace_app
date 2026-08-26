## Context

The per-site SOCKS5 path on iOS is production-ready in the WebSpace fork
of `flutter_inappwebview`: setting `proxySettings` on `WebViewConfig`
plumbs through `_userProxyToInappProxy`
([lib/services/webview.dart](../../../lib/services/webview.dart)) into
the fork's `preWKWebViewConfiguration` hook, which attaches a
`ProxyConfiguration` to the per-site `WKWebsiteDataStore`
([proxy/spec.md PROXY-008](../../specs/proxy/spec.md#requirement-proxy-008---android--ios-concurrency-asymmetry)).
The Dart-side seam is equally complete: `outboundHttp.clientFor` routes
favicon / download / user-script fetches through `socks5_proxy`'s TCP
tunnel with fail-closed posture on malformed addresses
([ip-leakage/spec.md LEAK-003](../../specs/ip-leakage/spec.md#requirement-leak-003---socks5-tunneling-and-fail-closed-posture)).

What is missing on iOS is a SOCKS5 *server* the user can point at. Apple
does not bundle one, there is no system Tor service, and Orbot — the
de-facto Android solution — has no iOS analogue because `VpnService`
does not exist there. The historical answer is to embed Tor in-process:
this is what Onion Browser does using
[`iCepa/Tor.framework`](https://github.com/iCepa/Tor.framework), a
CocoaPods-distributed static framework that wraps upstream `tor`,
`OpenSSL`, and `libevent` for iOS and macOS. We adopt the same.

Stakeholders: privacy-focused iOS users (primary), the F-Droid /
Play-only Android tier (no impact — Android stays generic SOCKS5,
Orbot users keep their existing config), and the iOS App Store review
process (export-compliance declaration must be updated to match Onion
Browser's "uses exempt encryption").

Constraints from the existing codebase:

- Logic engines live in `lib/services/*_engine.dart` as pure-Dart with
  mockable interfaces; `TorService` follows that pattern — the Swift
  plugin is a thin method-channel surface, all state-machine work
  happens in Dart and is unit-testable.
- Per-site settings must reach nested webviews (CLAUDE.md "Per-site
  settings MUST apply to nested webviews"): `useTor` rides through
  `WebViewModel.toJson` → `WebViewConfig` → `launchUrl` →
  `InAppWebViewScreen` exactly like every other per-site field.
- Secrets in `flutter_secure_storage`, never JSON: the Tor SOCKS auth
  password is ephemeral (random per app launch) and lives only in
  memory; no persistence path.
- F-Droid build must not regress: the iOS-only Pod is gated by the
  `Podfile` platform clause; Android's `build.gradle` is untouched.

## Goals / Non-Goals

**Goals:**

- One per-site toggle ("Route through Tor") that gives a user
  stream-isolated Tor browsing in a real WebView, with every existing
  WebSpace privacy layer (containers, content blocker, ETP shim,
  ClearURLs, DNS blocking, per-site geolocation/language) layered on
  top.
- Per-siteId stream isolation: two `useTor` sites coexisting in
  container mode get distinct exit IPs and uncorrelatable circuits;
  the same site after a "rebuild circuits" tap gets a fresh circuit
  but other sites are unaffected.
- App-global Tor for Dart-side traffic (DNS blocklist downloads,
  ClearURLs, content-blocker filter lists, OSM tiles) when the global
  outbound proxy is set to `TOR` — same SOCKS5 endpoint, distinct
  isolation tag so it can't be correlated with a site.
- Fail-closed: if Tor is configured but not bootstrapped, the affected
  webview shows a "Tor is bootstrapping…" interstitial; the affected
  Dart-side seam returns `OutboundClientBlocked` exactly like
  malformed SOCKS5 today. No silent fall-through to direct.
- Zero impact on non-Tor users: Tor process is not started unless a
  site or the global setting opts in, and is shut down once nothing
  needs it (debounced).

**Non-Goals:**

- Android — not deferred, **ruled out** for `ProxyType.TOR`. Orbot
  already exposes a local SOCKS5 port, so pointing the existing
  per-site SOCKS5 setting at `127.0.0.1:9050` works today and keeps
  working. What cannot work is the part that makes this feature worth
  having: Chromium's network stack implements no SOCKS5
  authentication (`net/docs/proxy.md`; crbug 40323993, open since
  2014), and Android WebView's per-site proxy goes through Chromium.
  Without the auth tuple, Tor cannot tell one site's streams from
  another's, so every site on Android would silently share circuits.
  Offering a "Tor" toggle that quietly drops isolation is worse than
  offering none, so Android keeps the honest manual SOCKS5 row.
  Revisit only if Chromium ships SOCKS5 auth.
- Linux, macOS — deferred. Linux users have system `tor`; macOS gets
  it once iOS proves out (Tor.framework supports macOS already, but
  the BackgroundTask contract is iOS-specific).
- Tor Bridges / Pluggable Transports UI (`obfs4`, `snowflake`,
  `webtunnel`). Initial cut uses default directory authorities; users
  in heavily-censored networks still need to wait for the
  `add-ios-tor-bridges` follow-on.
- Hidden-service (`.onion`) UX polish — error pages, security
  indicators, single-hop client onion-only mode. Works incidentally
  out of the SOCKS5 routing but is not part of this change's UX
  surface.
- A separate "Tor circuit picker" or "show me my exit node" UI; we
  only expose bootstrap % and a "rebuild circuits" button.
- Becoming a Tor relay / bridge ourselves. We are a Tor *client* only.
- Replacing the existing `socks5_proxy` Dart seam. Tor is *the source
  of* the SOCKS5 endpoint; the Dart and webview client paths are
  unchanged.

## Decisions

### D1. Tor runtime — embed Tor.framework, manage from Swift

Vendored via CocoaPods: `pod 'Tor', '409.11.2'` — an exact version,
not a `~>` range. The pod is MIT-licensed; the code it wraps is tor
(BSD-3), OpenSSL 3.x (Apache-2.0) and libevent (BSD). No GPL or LGPL
component enters the bundle, which is what makes an embed like this
distributable on the App Store at all.

Note the pod resolves `tor.xcframework` by downloading a precompiled
binary from GitHub releases during `pod install`. That is a build-time
fetch, so Guideline 2.5.2 (no downloading or executing code) is not
engaged — the binary is inside the submitted bundle. It is still a
supply-chain seam: pin the exact version and verify the downloaded
artifact's checksum in CI rather than trusting the release URL.

Why Tor.framework specifically:

- Battle-tested in Onion Browser, Tails, and several iOS Tor
  integrations. We get bug fixes, OpenSSL updates, and Apple
  compatibility patches for free.
- Ships precompiled fat XCFramework + dependencies — no in-tree C
  toolchain, no Bitcode pain.
- Exposes a high-level `TorThread` + `TorConfiguration` Swift API
  (no need to drive `tor` as a subprocess; iOS would not let us
  anyway).

**Alternatives considered**:

- Bundling raw `tor` C source via CocoaPods source build — fragile,
  slow CI builds, and we'd be on the hook for OpenSSL CVEs ourselves.
- Network Extension (`NEPacketTunnelProvider`) running Tor as a VPN —
  ergonomically attractive (covers other apps too), but requires the
  Network Extension entitlement (paid-developer-account-only,
  blocked on F-Droid sibling considerations), demands a separate
  process target with its own memory budget, and the user-visible
  "VPN" indicator is a non-starter for an app that already has its
  own privacy posture. Rejected.

  This rejection is also what keeps the change clear of Guideline
  5.4, which is the guideline that looks most threatening to anything
  Tor-shaped: *"Apps that offer VPN services must obtain permission
  from the user before using their device as a VPN server. If your
  VPN app doesn't connect to a server you own or contract with, it
  doesn't belong on the App Store."* A Tor VPN would fail that second
  sentence outright — Tor relays are by definition not servers we own
  or contract with. An in-process SOCKS5 listener that only its own
  app dials is not a VPN service: no `NEVPNManager`, no
  NetworkExtension entitlement, no system VPN indicator, no traffic
  from any other app, and the device never acts as a server. Record
  this as a compliance decision, not only an ergonomic one: choosing
  the loopback-proxy architecture is what makes 5.4 inapplicable, so
  a later "let's cover other apps too" proposal reopens it.
- Recommending Orbot for iOS (a port exists in TestFlight). Out of
  our control, not on the App Store stable channel as of 2026-05;
  user has to install separately. We can still document this as an
  alternative for the bridge-needing minority.

### D2. Lifecycle — lazy start, debounced idle stop

`TorService` is a singleton owning a state machine:

```
stopped → starting → bootstrapping(pct) → up → stopped
            │                              │
            └──────── error(msg) ──────────┘
```

Transitions:

- `stopped → starting`: triggered by `maybeStart()`. Callers are
  `main.dart` (cold-start scan for any `useTor` site or
  `globalOutboundProxy.type == TOR`), per-site settings save
  (`updateProxySettings`), and `GlobalOutboundProxy.update`.
- `starting → bootstrapping`: Swift `TorThread.start()` returns; we
  subscribe to control-port events.
- `bootstrapping(pct) → up`: 100% bootstrap reported by control port.
- `up → stopped`: debounced 60s after the last user. `TorService`
  tracks a refcount of (`useTor` site count + `globalOutboundProxy ==
  TOR ? 1 : 0`); when it hits 0 a 60-second timer starts; refcount
  going back up cancels the timer.
- `* → error`: bootstrap timeout (90s default), or unrecoverable
  control-port disconnect.

Why a refcount + 60s debounce rather than always-on or always-off:

- Always-on costs ~30 MB of RSS + ongoing directory traffic for users
  who only use Tor occasionally — bad on memory-pressured iOS.
- Always-off (start-on-tap, stop-on-blur) would re-bootstrap on every
  site activation; bootstrapping takes 10-30s on real networks. The
  60s debounce covers webspace-switching and short bursts without
  thrashing.
- 60s is the same magnitude as iOS's BackgroundTask grace window,
  which simplifies the interaction below (D6).

**Alternative considered**: per-site `TorThread` instances for stream
isolation. Rejected — `TorThread` does not support multiple instances
per process (only one consensus subscription at a time). Stream
isolation goes through SOCKS auth instead (D3).

### D3. Stream isolation — `IsolateSOCKSAuth` + per-site SOCKS user

Tor isolates streams by SOCKS5 username/password tuple whenever
`SocksPort` carries `IsolateSOCKSAuth`, which per `tor(1)` is "On by
default; you can disable it with NoIsolateSOCKSAuth" — as is
`IsolateClientAddr`. We still write the flags explicitly in our
`TorConfiguration` so the isolation contract is legible at the
config rather than inherited silently from an upstream default that
could change. We set:

- SOCKS5 username = `siteId` (UUID; never the human-readable site name)
- SOCKS5 password = a random 32-byte hex string generated once per
  app launch and held in `TorService._sessionSecret`. Used purely as
  an unguessable seal; Tor does not authenticate against it.

Consequences:

- Two sites: distinct circuits, distinct exit IPs, no linkability
  inside Tor.
- Same site across app launches: distinct circuits (new password),
  matching the user's intuition that the app didn't remember Tor
  state.
- Same site across iOS process lifetime (foreground/background
  flipping that doesn't kill the process): same circuit — that is
  what stream isolation means; a "rebuild" requires the explicit
  button.
- Dart-side app-global traffic uses a synthetic siteId
  `__webspace_app_global__` so it can't be correlated with any site.
- The `socks5_proxy` Dart package and the fork's iOS
  `ProxyConfiguration` both accept username/password, so the
  same translation maps to both code paths.

**Alternative considered**: `NEWNYM` signal on every site activation
to force fresh circuits. Rejected — `NEWNYM` is global (would
invalidate every site's circuit at once), and it is rate-limited.
Stream isolation gives us the right granularity for free.

### D4. Surface area — Swift plugin + Dart service

```
ios/Runner/TorControllerPlugin.swift
  ├── FlutterMethodChannel "<bundle>/tor"
  │   ├── start()        → starts TorThread with our TorConfiguration
  │   ├── stop()
  │   ├── status()       → returns {state, bootstrapPct, socksPort}
  │   ├── rebuildCircuits()  → posts SIGNAL NEWNYM via control port
  │   └── socksEndpoint() → "127.0.0.1:<dynamicPort>"
  └── FlutterEventChannel "<bundle>/tor/events"
      └── streams {state, bootstrapPct, lastError}

lib/services/tor_service.dart
  ├── TorService.instance.maybeStart(reason)
  ├── TorService.instance.release(reason)
  ├── TorService.instance.statusStream  → Stream<TorStatus>
  ├── TorService.instance.socksFor(siteId, perAppGlobalTag?)
  │       → UserProxySettings(SOCKS5, addr, user, pwd)
  ├── TorService.instance.rebuildCircuits()
  └── private debounce timer + refcount
```

`socksFor` is where the stream-isolation contract lives — it is the
single function called by both `outboundHttp.clientFor` and
`_userProxyToInappProxy` to materialize the per-call SOCKS5 settings.
Test coverage: feeding two distinct siteIds returns settings whose
usernames differ; the global-traffic tag is never equal to a real
siteId.

### D5. SOCKS port allocation — dynamic, never hardcoded

Tor's default SOCKS port is 9050. We do **not** use it: another app
(Orbot/Onion Browser if the user has both) may already own it, and
iOS does not let us know whether a port is free without trying.

`TorConfiguration` sets `SocksPort auto IsolateSOCKSAuth
IsolateDestAddr` — Tor picks a free loopback port itself and reports
it on the control port. `TorService` reads it after bootstrap and
exposes it via `socksEndpoint`. Any code that hardcodes `9050` is a
bug.

### D6. Background-task contract — extend existing grace window

`BackgroundTaskService`
([ios/Runner/BackgroundTaskPlugin.swift](../../../ios/Runner/BackgroundTaskPlugin.swift))
already opens a ~30s `beginBackgroundTask` window on app pause for
notification sites. We extend its decision:

- App pause: if any `useTor` notification site exists, the
  background-task window includes "do not stop Tor". Otherwise, the
  60s `TorService` debounce starts as normal; the OS may or may not
  kill the process before it fires, and either outcome is fine
  (cold-start re-bootstraps).
- `BGAppRefreshTask` for notification sites: if those sites have
  `useTor=true`, the task pre-warms Tor (starts bootstrap before
  reloading the site) so the reload doesn't 30s-time-out on a cold
  bootstrap.

### D7. Failure surfacing — interstitial for webview, blocked for Dart

When `TorService.status != up` and a `useTor` request is in flight:

- Native WebView: the URL is intercepted by an existing
  `WebViewModel` policy hook and rewritten to
  `webspace://tor-bootstrap?next=<original>` which a small custom
  Flutter screen renders (progress bar bound to `statusStream`).
  Once `up`, it auto-navigates back to `next`. If `status == error`,
  it shows the error + "Retry" button.
- Dart-side: `outboundHttp.clientFor(useTor)` returns
  `OutboundClientBlocked` exactly like the malformed-SOCKS5 case
  today; tests use the existing `RecordingFactory` to assert that
  no fallback `http.Client` is constructed.

**Alternative considered**: queue the request inside `OutboundHttp`
and drain it on `up`. Rejected — the Dart-side seam is used for
fetches the user is not visually waiting on (background DNS list
refresh); silently delaying them is worse than failing fast and
letting the caller's existing retry logic kick in.

### D8. Privacy manifest and export compliance

**Privacy manifest.** Required-reason API declarations go in a
`PrivacyInfo.xcprivacy` resource, not `Info.plist` — Apple does not
read `NSPrivacyAccessedAPITypes` from `Info.plist`, so a declaration
placed there is silently absent at review. The repository ships no
privacy manifest today, so this change adds the first one and the app
declares only the required-reason APIs *it* calls. Tor.framework is
responsible for its own manifest inside its own bundle; if the pinned
pod ships none, that is an upstream gap to raise, not something the
app can declare on the pod's behalf. See TOR-011.

**Export compliance.** The app currently declares
`ITSAppUsesNonExemptEncryption = false`. That declaration does not
survive this change. Apple's exemption covers encryption provided by
the operating system (HTTPS via `URLSession`) and encryption used
purely for authentication; Tor.framework ships tor's own TLS and
onion-routing cryptography plus a full OpenSSL build *inside our
binary*, which is encryption the app implements. The key flips to
`true`, export-compliance documentation is filed in App Store Connect
before the first Tor build is submitted, and the annual
self-classification report to BIS joins the release checklist.

Two honest notes on this. First, the flip is arguably owed already:
the app implements AES at rest in `archive_crypto.dart` and
`html_cache_service.dart`, so the current `false` is questionable on
its own terms and Tor only makes it unambiguous. Second, the earlier
draft of this design asserted the opposite — that the exemption
"remains valid" and "no plist change is needed" — by reasoning from
Onion Browser's posture rather than from Apple's stated exemption
categories. That was wrong, and it is the single highest-cost error
in the change: a false submission-form declaration is a
misrepresentation to Apple and a U.S. export-control exposure, not a
guideline nit that review would simply bounce back. See TOR-010.

## Risks / Trade-offs

- **[Binary size growth ~15 MB]** → mitigation: the framework only
  ships in iOS builds (the Pod is platform-gated). F-Droid Android
  apk is unaffected. iOS users get the bytes whether or not they
  enable Tor — acceptable for a privacy app where the feature is
  one tap away.
- **[Tor.framework upstream churn]** → mitigation: pin to a specific
  tag in `Podfile`. Treat upgrades like any other dependency bump —
  run the manual iOS test matrix after each.
- **[Bootstrap UX on flaky networks]** → mitigation: 90s timeout
  surfaces an explicit error; the "Tor is bootstrapping…"
  interstitial shows the progress bar so the user knows it isn't
  frozen.
- **[iOS process kill during bootstrap]** → mitigation: when iOS
  kills our process before bootstrap completes, the next cold-start
  restarts the state machine from scratch. No persistent state
  between runs (we don't persist circuits / DataDirectory beyond
  what Tor.framework caches internally).
- **[User confusion: "Tor is on but my site still says I'm in X"]**
  → mitigation: the per-site Settings screen shows the current exit
  country (via Tor control-port `GETINFO ip-to-country`) so the user
  sees evidence Tor is working. Out of scope for this change to
  surface in the main app bar, but acceptable as a settings detail.
- **[App Store review]** → no guideline in the current App Store
  Review Guidelines prohibits this design; the exposure is
  concentrated in three places and each has an owner in the spec.
  (a) Guideline 2.1, App Completeness, is the likeliest rejection:
  review runs on a corporate network where bootstrap may be blocked,
  and a reviewer who sees an untimed spinner reads a broken feature
  (TOR-013 requires a bounded, plain-language failure plus App Review
  notes). (b) Guideline 5.2.5 plus the Tor Project's own trademark
  policy constrain how the marks may appear — descriptive use only,
  never a product name or the onion logo (TOR-012). (c) The
  export-compliance declaration must flip to `true` (TOR-010).
  Precedent is strong for the architecture itself: Onion Browser has
  shipped since 2012, is endorsed by the Tor Project, and takes the
  same approach this design takes — iOS forbids a system-wide Tor
  service, so tor is compiled into the binary and run as an
  in-process thread.
- **[Tor exit nodes blocked by sites the user cares about]** → out
  of scope; this is intrinsic to Tor, not a code-level concern. The
  per-site nature of the toggle is itself the mitigation: don't
  flip `useTor` on your bank site.

## Migration Plan

- Phase 1 (this change): ship `useTor` per-site + `ProxyType.TOR`
  global, default off everywhere. Existing per-site SOCKS5 configs
  (including users manually pointing at `127.0.0.1:9050`) keep
  working unchanged.
- No data migration needed: `useTor` is a new field defaulting
  `false`; `ProxyType.TOR` is a new enum value, existing serialized
  proxies (DEFAULT/HTTP/HTTPS/SOCKS5) decode unchanged.
- Settings backup round-trips automatically through the
  `kExportedAppPrefs` registry and per-site `toJson` — see
  CLAUDE.md "Adding a new global app setting" / "Per-site settings".
- Rollback: revert this change → `useTor` field is ignored on load
  (forward-compat); `ProxyType.TOR` decodes to `DEFAULT` via a
  fall-back. Users who exported a backup with TOR set will see their
  global proxy revert to system default after rollback + import.

## Open Questions

- Should the per-site UI offer a "country (advanced)" exit-node
  preference, or strictly leave that to Tor's path selection? Lean
  no — user-configurable exit countries are a footgun (linkability)
  and a support-burden surface. Revisit only if requested.
- Do we want an icon badge on the URL bar when `useTor` is active?
  Surface area for a future polish PR; not required for this change.
- macOS port timing — deferral is a hard constraint, not a
  preference: the pod requires macOS 12.0, while `macos/Podfile` is
  `platform :osx, '10.15'` and the project builds against
  `MACOSX_DEPLOYMENT_TARGET = 10.15`/`11.0`. A follow-on
  (`add-macos-tor-proxy`) has to raise the deployment target first,
  which drops macOS 10.15 and 11 users; that is its own decision to
  make deliberately rather than as a side effect.
