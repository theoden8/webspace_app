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

## 4. Open

- [ ] 4.1 **On-device validation of the per-profile auth cache.** Run
      `integration_test/proxy_router_test.dart` on Android with two
      containers and confirm the relay log shows two distinct credentials.
      One credential for both sites means the gate assumption is wrong and
      router mode must be withdrawn.
- [ ] 4.2 Service-worker cold start: `AwHttpAuthHandler::Start` cancels
      when there is no `WebContents`, so a service-worker request that
      arrives before the profile's auth cache is warm fails closed. Decide
      whether to prewarm.
- [ ] 4.3 Settings copy: PROXY-008's "switching cold-starts the other
      site" explanation no longer applies under router mode.
- [ ] 4.4 `formal/proxy.tla`: add router mode so `Inv_ProxyCoherent` is
      conditioned on it rather than assumed.
