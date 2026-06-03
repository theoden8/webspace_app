## Why

Authenticated proxies do not work on Android. The data model accepts a
username/password, and `ProxyManager.setProxySettings` embedded them in the
proxy URL handed to `inapp.ProxyController` as
`scheme://user:pass@host:port`. Android's WebView `ProxyController` has no
proxy-authentication primitive, and Chromium rejects a proxy rule that
carries userinfo — so the rule is dropped and the WebView **silently falls
back to a direct connection**, leaking the user's real IP (the exact
opposite of what the user asked for). The failure was swallowed in
`_applyProxySettings`, so there was no surfaced error either.

This is a platform gap, not user error: Chrome's own WebView cannot do
authenticated proxies via `ProxyController`. The established fix (used by
e.g. Alibaba's HTTPDNS WebView integration) is a local loopback proxy that
fronts the authenticated upstream: WebView talks to `127.0.0.1` with no
credentials, and the relay injects them on the way out.

iOS 17+/macOS 14+ already carry credentials on the per-site
`WKWebsiteDataStore.proxyConfigurations`; Linux/WebKit accepts a
credentialed proxy URI directly. Only Android needs the relay.

## What Changes

- **Native loopback relay (`ProxyRelay`, Kotlin).** A small HTTP proxy that
  binds a random ephemeral port on `127.0.0.1` and forwards to the
  configured upstream, injecting credentials: HTTP `Proxy-Authorization:
  Basic` for HTTP/HTTPS upstreams, the SOCKS5 username/password handshake
  (RFC 1929) for SOCKS5. Handles `CONNECT` tunnels (HTTPS, the common case)
  and absolute-form HTTP. Deliberately free of `android.*` imports so it is
  unit-tested on the JVM (`ProxyRelayTest`) — no emulator.
- **Fail-closed by construction.** The relay only ever connects to the
  configured upstream; an unreachable upstream or rejected auth yields a
  `502` to the client, never a direct connection. Random port is
  re-bound on every (re)start and never persisted; the listener binds to
  loopback only.
- **`ProxyRelayPlugin` + method channel** (`.../proxy_relay`) with
  `start` / `stop` / `isRunning`. Runs on daemon JVM threads in the app
  process, independent of the Flutter engine lifecycle, so background
  notification-refresh sites keep proxying.
- **Dart wiring.** On Android, when the effective proxy has credentials,
  `ProxyManager.setProxySettings` starts the relay (`ProxyRelay` in
  `lib/services/proxy_relay.dart`) and points `ProxyController` at
  `http://127.0.0.1:<port>` with no credentials. If the relay cannot bind,
  it throws rather than clearing the override (no direct-connection leak).
  Unauthenticated proxies and Linux keep the direct `ProxyController` path.
- **CI.** Add a JVM unit-test lane (`./gradlew testDebugUnitTest`) so the
  relay (and the existing `src/test/kotlin` suites) run on every push.

## Out of Scope

- iOS/macOS/Linux proxy auth (already supported natively).
- Confirming whether per-site container profiles honor the global
  `ProxyController` override: documented contract says the override applies
  to all WebViews app-wide, and the relay sits underneath `ProxyController`
  either way. An on-device egress-IP check is tracked as a verification
  task, not a code change.
