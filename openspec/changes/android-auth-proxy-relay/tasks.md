## 1. Native relay (Kotlin)

- [x] 1.1 `ProxyRelay` in `android/app/src/main/kotlin/.../proxy/ProxyRelay.kt` — loopback HTTP proxy, random ephemeral port, `android.*`-free. `CONNECT` tunnel + absolute-form forward.
- [x] 1.2 HTTP/HTTPS upstream: inject `Proxy-Authorization: Basic`. HTTPS upstream wrapped in TLS.
- [x] 1.3 SOCKS5 upstream: greeting + RFC 1929 username/password auth + domain-ATYP CONNECT (no local DNS leak).
- [x] 1.4 Fail-closed: only ever connect to the configured upstream; `502` on failure; never direct.
- [x] 1.5 Hand-rolled Base64 (no `android.util.Base64`, no API-26 `java.util.Base64`).

## 2. Native plugin

- [x] 2.1 `ProxyRelayPlugin` method channel (`.../proxy_relay`) with `start` / `stop` / `isRunning`.
- [x] 2.2 Register + dispose in `MainActivity`.

## 3. Dart wiring

- [x] 3.1 `ProxyRelay` client in `lib/services/proxy_relay.dart` (Android-only).
- [x] 3.2 `ProxyManager.setProxySettings`: credentialed Android proxy → start relay, point `ProxyController` at `127.0.0.1:<port>` (no creds); throw (fail closed) on relay-start failure.
- [x] 3.3 Stop the relay on the DEFAULT/clear path, the unauthenticated path, and `clearProxy()`.
- [x] 3.4 Preserve the inline-credential URL on the non-Android (Linux) path.

## 4. Tests

- [x] 4.1 `ProxyRelayTest` (JVM): Base64 vectors, distinct random ports, HTTP `Proxy-Authorization` injection (fake upstream), SOCKS5 RFC 1929 handshake (fake upstream), fail-closed `502`. Verified passing via standalone `kotlinc` + JUnit.
- [x] 4.2 CI: the existing `Run JVM unit tests` step (`gradle :app:testFdroidDebugUnitTest`, build-and-test.yml) auto-discovers `src/test/kotlin` and runs `ProxyRelayTest` — no workflow change needed.
- [ ] 4.3 On-device egress-IP verification: with a plain (unauthenticated) proxy under containers, confirm egress IP changes — settles whether container profiles honor the global `ProxyController`. Manual / instrumentation; not automatable in the current CI.

## 5. Specs

- [x] 5.1 PROXY-010 / PROXY-011, LEAK-008 deltas.
- [x] 5.2 `openspec validate android-auth-proxy-relay --no-interactive` clean.
- [ ] 5.3 On apply: fold the relay note into `openspec/specs/proxy/spec.md` Android row and the `ProxyManager` docstring (done in code) + ip-leakage coverage matrix.
