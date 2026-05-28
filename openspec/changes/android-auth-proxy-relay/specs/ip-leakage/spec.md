## ADDED Requirements

### Requirement: LEAK-008 - Android webview auth-proxy fail-closed

On Android, applying a credentialed proxy to the WebView SHALL NOT degrade
to a direct connection on failure. Credentials SHALL NOT be embedded in the
`inapp.ProxyController` proxy rule (Chromium rejects userinfo and silently
goes direct); they SHALL instead be injected by the native loopback relay
(see PROXY-010 / PROXY-011), which only ever connects to the configured
upstream. Credentials SHALL travel to the relay only over the loopback
method channel and SHALL NOT appear in any `ProxyController` rule or on any
non-loopback socket from the app. If the relay cannot be established, the
webview proxy application SHALL fail closed (no override cleared, no direct
fallback) consistent with the SOCKS5 fail-closed posture in LEAK-003.

#### Scenario: Credentialed Android proxy never sets a userinfo rule

- **GIVEN** the app runs on Android with a credentialed effective proxy
- **WHEN** the proxy is applied
- **THEN** the `ProxyController` rule is `http://127.0.0.1:<port>` with no userinfo
- **AND** the username and password are present only in the relay's upstream connection

#### Scenario: Relay failure does not leak the IP

- **GIVEN** a credentialed Android proxy whose relay cannot start
- **WHEN** the proxy is applied
- **THEN** no direct-connection override is left active for that site's traffic
- **AND** the failure is logged at error level
