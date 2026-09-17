## Why

Android cannot point two WebViews at two proxies.
`androidx.webkit.ProxyController` carries one process-wide rule, and it is
profile-blind: it applies to every WebView regardless of which
`androidx.webkit.Profile` the site runs in. PROXY-008 makes that safe by
serialising — activating a site disposes every loaded site whose effective
proxy differs, so per-site routing is honoured at the cost of cold-starting
the others. iOS 17+ / macOS 14+ have no such cost: the proxy is attached to
the per-site `WKWebsiteDataStore`.

The case this hurts is the one the feature exists for: two accounts on one
service, each meant to be seen from its own exit IP. Every switch between
them is a cold start.

The gap is not the proxy, it is **attribution**. The relay added by
`android-auth-proxy-relay` already fronts one upstream on loopback; it
cannot front several because a TCP connection arriving on `127.0.0.1`
carries nothing that says which site opened it. Same UID, same process,
same network stack.

Chromium does expose exactly one per-WebView channel that can carry that
information, and it is the proxy's own `407`:
`AwContentBrowserClient::CreateLoginDelegate` builds an `AwHttpAuthHandler`
for a proxy challenge with **no `is_proxy` branch**, passing the
`WebContents` that issued the request, which surfaces as
`WebViewClient.onReceivedHttpAuthRequest` on that specific WebView.

Note the direction: what Android lacks is a way to *preconfigure* proxy
credentials, which is why the relay exists at all. Answering a challenge is
a different mechanism and it works. It works only for a plain HTTP proxy —
an HTTPS proxy yields `ERR_PROXY_AUTH_UNSUPPORTED` and no callback — so the
relay must stay unencrypted on loopback, which costs nothing there.

## What Changes

- **Router mode in `ProxyRelay` (Kotlin).** The relay fronts every site at
  once, selecting the upstream from the `Proxy-Authorization` credential
  the WebView presents. No credential gets a `407`; an unknown one gets a
  `502`. A new `DIRECT` upstream type serves sites the user left on the
  system default, since the process-wide rule now sends their traffic here
  too.
- **`ProxyRouterEngine` / `ProxyRouterState` (pure Dart).** Mints the
  per-site tokens and the realm nonce, builds the route table, and owns the
  challenge-admission policy.
- **`ProxyRouterService`.** Relay lifecycle plus the runtime question the
  WebView layer asks: "is this challenge yours, and what do I answer?"
- **`answerProxyRouterChallenge` in `webview.dart`.** Wired into every
  WebView the app builds. Keyed by `siteId` rather than threaded through
  `WebViewConfig`, so popups and the nested `InAppWebViewScreen` cannot be
  built without it.
- **PROXY-008 serialisation lifts under router mode.**
  `SiteUnloadEngine.indicesToUnloadForProxyMismatch` is passed
  `proxyIsGlobal: false`, and `ProxyConflictEngine` takes a `routerActive`
  flag that lifts the background-poll restriction.
- **The relay's inbound socket gains admission control.** Previously it
  tunnelled for any local caller.

## Gating, and why it is not optional

Router mode requires container mode (`WebViewFeature.MULTI_PROFILE`).
Chromium's `HttpAuthCache` is owned by the `HttpNetworkSession`, and proxy
entries are deliberately **not** keyed by `NetworkAnonymizationKey`, so
within one session a single cached proxy credential serves every request.
The profile boundary is the only thing separating site A's token from site
B's. Without `MULTI_PROFILE` every site would present the first site's
credential and route through its proxy — a silent cross-site IP leak,
strictly worse than the cold start PROXY-008 costs. On that path the app
keeps PROXY-008.

This is the one assumption in the design that could not be confirmed from
Chromium's source. It is asserted on-device by
`integration_test/proxy_router_test.dart`; if it does not hold, the
observable symptom is one credential appearing for two sites in the relay
log, and router mode must be withdrawn rather than patched.

## Impact

- Affected specs: `proxy` (PROXY-013), `ip-leakage` (LEAK-009).
- Affected code: `ProxyRelay.kt`, `ProxyRelayPlugin.kt`,
  `lib/services/proxy_relay.dart`, `proxy_router_engine.dart` (new),
  `proxy_router_service.dart` (new), `webview.dart`,
  `proxy_conflict_engine.dart`, `main.dart`.
- No data-model change: per-site `proxySettings` is untouched, so a
  settings backup moves between platforms exactly as before.
