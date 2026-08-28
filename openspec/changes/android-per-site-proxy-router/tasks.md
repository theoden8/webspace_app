## 1. Relay (Kotlin)

- [x] 1.1 Router mode: realm nonce, credential -> route snapshot, `407` /
      `502` admission, no default upstream.
- [x] 1.2 `DIRECT` upstream for sites on the system default; never a
      fallback for a site whose proxy failed.
- [x] 1.3 BUG-007 discipline: `routerRealm` / `routes` replaced wholesale
      under the monitor, read as one volatile snapshot.
- [x] 1.4 `startRouter` / `setRoutes` on the method channel, rejecting a
      malformed table whole rather than installing it partially.

## 2. Dart

- [x] 2.1 `ProxyRouterEngine`: nonce minting, credential format, challenge
      admission policy, route table + wire encoding.
- [x] 2.2 `ProxyRouterState`: in-memory token registry with revocation.
- [x] 2.3 `ProxyRouterService`: lifecycle, fail-closed activation,
      `ownsChallenge`.
- [x] 2.4 `answerProxyRouterChallenge` wired into every WebView, keyed by
      `siteId`.
- [x] 2.5 `ProxyManager.applyRouterOverride`; per-site `setProxySettings`
      becomes a no-op under router mode.
- [x] 2.6 Lift PROXY-008 unload and the `ProxyConflictEngine` restriction.
- [x] 2.7 Activation at startup and route refresh on model save.

## 3. Tests

- [x] 3.1 JVM, real sockets: admission (`407` / `502` with a counting
      upstream), per-credential routing, concurrent distinct upstreams,
      token never forwarded upstream, revocation, direct route, no
      fallback from a dead proxy to a co-resident direct route, background
      polling with no reconfiguration.
- [x] 3.2 Dart: engine policy, service lifecycle and fail-closed paths,
      unload/conflict gating.
- [x] 3.3 Browser tier, real Chromium: page cannot set
      `Proxy-Authorization`, cannot read the token, cannot use the relay
      unauthenticated; the origin never sees the token.
- [x] 3.4 Integration: router comes up only where it can be honoured; the
      process-wide rule names the relay.

## 4. Attribution self-test (PROXY-015)

- [x] 4.0 Relay answers `.webspace-probe.invalid` locally, opens no
      upstream, and records nonce -> siteId; `probeResults` /
      `clearProbeResults` on the channel.
- [x] 4.0.1 `ProxyRouterEngine.attributionHolds` / `attributionFailures`,
      and `ProxyRouterService.activate(probe:)` refusing activation on any
      mismatch, missing pair, or probe error.
- [x] 4.0.2 Real probe via a short-lived headless WebView per container
      (`proxy_router_probe.dart`) -- not an injected fetch, which a page
      CSP could block and make look like a broken device.
- [x] 4.0.3 Tests: JVM (probe answered locally, never upstream; pairs
      recorded per credential; unadmitted caller records nothing) and Dart
      (a simulated shared-auth-cache device is refused).

## 4b. Open

- [ ] 4.1 **On-device validation of the per-profile auth cache. STILL
      OPEN, and CI cannot close it.** The emulator tier runs the gate
      (`proxy_router_attribution_test.dart`) but the api-34/google_apis
      image ships **WebView 113.0.5672.136**, which does NOT report
      `MULTI_PROFILE` (measured: the wrapper prints the version, and the
      run logs `Container API not supported`). Router mode therefore never
      activates and the test SKIPS while the Build Android job goes green,
      so a green CI run is NOT evidence for this item. androidx does not
      document the milestone that adds the feature; the measured fact is
      that 113 lacks it. Closing this needs an emulator image or device
      whose WebView does report `MULTI_PROFILE`.
      Note PROXY-015 now makes this fail-safe rather than fail-silent: a
      device that cannot attribute refuses router mode instead of mixing
      sites. The on-device run is still wanted, to confirm the happy path
      actually activates rather than always falling back. Only one reached means Chromium shares an
      `HttpAuthCache` across container profiles and router mode must be
      withdrawn, not patched.
      Note this also means container mode itself is unexercised by the
      current emulator tier, which is a pre-existing gap.
- [ ] 4.2 Service-worker cold start: `AwHttpAuthHandler::Start` cancels
      when there is no `WebContents`, so a service-worker request that
      arrives before the profile's auth cache is warm fails closed. Decide
      whether to prewarm.
- [ ] 4.3 Settings copy: PROXY-008's "switching cold-starts the other
      site" explanation no longer applies under router mode.
- [x] 4.4 `formal/proxy.tla`: router mode added. The asserted safety
      property is now `Inv_EgressMatchesConfig` (every loaded site
      egresses through the proxy it was configured with), which holds in
      both modes; `Inv_ProxyCoherent` is demoted to PROXY-008's mechanism
      and asserted only in the "off" configs. The `misattribute`
      demonstrator encodes the shared-`HttpAuthCache` failure the
      on-device gate hunts for, and `Reach_MismatchedCoLoaded` is checked
      from both sides: reachable under the router, unreachable under
      serialisation.
