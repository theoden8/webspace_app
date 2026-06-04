# TLS Trust Prompt Specification

## Status
**Implemented**

## Purpose

Define the contract for handling TLS certificate validation in the
embedded webview and in Dart-side HTTP clients. The app respects the
platform's system + user-installed CA trust store by default, prompts
the user with a confirmation dialog when (and only when) the OS rejects
a certificate, and persists an approved (host, port, sha256) triple so a
self-signed site the user trusted once loads silently on every
subsequent visit. The Dart-side `HttpClient.badCertificateCallback`
consults the same pin list so favicon probes, downloads, and the SOCKS5
raw-socket path don't fail on a host the user already trusted in the
webview.

## Problem Statement

Before this contract existed, the app registered an
`onReceivedServerTrustAuthRequest` handler that unconditionally
short-circuited platform validation. On iOS/macOS the upstream
`flutter_inappwebview` plugin forwards **every** server-trust challenge
to Dart — not just the failed ones — so every public CA-signed site
(github.com, googleapis.com, every CDN) hit the user prompt. Users
pinned dozens of leaf fingerprints for sites Apple Keychain would have
trusted, and CDN-fronted sites that serve different leaf certs per POP
re-prompted on every cert rotation.

The platform behavior is asymmetric:

| Platform     | Trust callback fires when…                            |
|--------------|--------------------------------------------------------|
| iOS, macOS   | Every TLS handshake (pre-evaluation)                  |
| Android      | OS rejected the cert (`WebViewClient.onReceivedSslError`) |
| Linux WPE    | OS rejected the cert (`load-failed-with-tls-errors`)  |

The contract below collapses that asymmetry into one user-visible flow:
"if and only if the OS rejected the cert, ask the user once and pin the
decision."

**Modern Apple platforms are the exception.** macOS 15+ and iOS 26+
WKWebView ignore `URLCredential(trust:)` for self-signed / unknown-CA
certs at the `nw_protocol_boringssl` layer regardless of how the
credential is delivered (sync / async, with / without
`SecTrustSetExceptions`, with / without `SecTrustEvaluateWithError`).
The only OS-supported override is installing the cert into the system
trust store, which app sandboxing blocks (`SecTrustSettingsSetTrustSettings`
on macOS, profile installation through MDM on iOS). Safari uses a
private WebKit SPI no third-party app has access to. The trust-prompt
path is therefore **skipped on iOS and macOS**: public CA-signed sites
work via the OS-default path, but self-signed sites fail closed and the
user must install the cert manually if needed (Keychain Access on macOS,
Settings → General → VPN & Device Management → Certificate Trust
Settings on iOS).

## Solution

Three coordinated pieces:

1. **`_handleServerTrust` (lib/services/webview.dart)** — pinned certs
   PROCEED; on iOS/macOS unpinned certs **return `null`** from the
   Future (NOT `ServerTrustAuthResponse()`, whose Dart constructor
   defaults `action` to `CANCEL` and silently kills the handshake). The
   null return routes through the upstream plugin's `nullSuccess` →
   `defaultBehaviour` → `.performDefaultHandling`, which delegates the
   verdict to Apple Keychain. On Android/Linux the callback is already
   post-failure, so unpinned certs go straight to the prompt.
2. **`_handleSslLoadError` (lib/services/webview.dart)** — wired into
   `onReceivedError` and triggered on any `SERVER_CERTIFICATE_*` /
   `FAILED_SSL_HANDSHAKE` / `SECURE_CONNECTION_FAILED` error code. Shows
   the prompt, pins on approval, reloads the URL. Bails out if the host
   is already pinned (stale event from the original failed nav after we
   reloaded).
3. **`TrustedHostsService` (lib/services/trusted_hosts_service.dart)** —
   persists `(host, port, sha256)` triples to SharedPreferences. The
   webview path and `HttpClient.badCertificateCallback` both consult it.

---

## Requirements

### Requirement: TLS-001 - System CA validation is honored by default

Public CA-signed sites SHALL load without a user prompt. The app SHALL
NOT intercept TLS challenges that the platform's trust store would
accept.

#### Scenario: Public CA site loads silently on iOS/macOS

**Given** the device's Apple Keychain trusts the root CA chain for `https://github.com`
**And** no pin exists for `github.com:443` in `TrustedHostsService`
**When** the user navigates to `https://github.com`
**Then** `_handleServerTrust` returns `null`
**And** the upstream Swift plugin invokes `completionHandler(.performDefaultHandling, nil)`
**And** the page loads
**And** no certificate prompt is shown
**And** a `[TLS/debug] deferring trust verdict to OS for github.com:443` log line is emitted

#### Scenario: Public CA site loads silently on Android

**Given** the Android System WebView's trust store accepts the cert chain for `https://github.com`
**When** the user navigates to `https://github.com`
**Then** `onReceivedSslError` is never invoked by the platform
**And** `_handleServerTrust` is never reached
**And** the page loads without a prompt

---

### Requirement: TLS-002 - Untrusted certs trigger a single user prompt on Android/Linux

The app SHALL show exactly one "Untrusted certificate" dialog per host
when the OS rejects a server cert and the cert is not pinned, on
Android and Linux. Re-entrant calls during prompt display SHALL be
coalesced so a cascade of failed sub-resource requests does not stack
identical dialogs. iOS and macOS are excluded — see TLS-009.

#### Scenario: First visit to a self-signed host on Android/Linux

**Given** `https://self-signed.example.com` presents a self-signed cert
**When** the user navigates to it
**Then** the OS rejects the chain pre-callback and fires the trust callback
**And** `_handleServerTrust` shows the prompt inline (no reload round-trip)
**And** approval pins the cert and the response action is `PROCEED`
**And** the reload succeeds and the page loads

#### Scenario: Prompt re-entrancy is coalesced

**Given** a TLS handshake to `self-signed.example.com:443` fires two error events in rapid succession (main frame + favicon probe)
**When** both events reach `_handleSslLoadError`
**Then** only one dialog is shown
**And** the second invocation returns `true` immediately (treated as handled by the in-flight prompt)

---

### Requirement: TLS-003 - Stale post-failure events are dropped after a pin

The app SHALL detect and ignore stale `onReceivedError` events for hosts
that are already pinned. After the user pins a cert and the URL is
reloaded, the platform MAY deliver the original failed-nav callback
late; the redundant prompt MUST NOT be re-shown.

#### Scenario: iOS delivers a stale `didFailProvisionalNavigation` after reload

**Given** `_handleSslLoadError` has just persisted a pin for `self-signed.example.com:443` and called `controller.loadUrl(...)`
**And** the reload's trust callback returned `PROCEED` ("pinned cert accepted" logged)
**When** WKWebView fires a late `onReceivedError` for the original failed navigation
**Then** `_handleSslLoadError` looks up the cached cert via `_sslCertificateCache[host:port]`
**And** checks `TrustedHostsService.isTrusted` with the cached fingerprint
**And** the pin matches, so the prompt is NOT re-shown
**And** a `[TLS/debug] ignoring stale ssl error for ... — already pinned` log line is emitted

---

### Requirement: TLS-004 - Dart-side HTTP client honors the same pin list

Every `HttpClient` created via `OutboundHttp._newHttpClient()` SHALL
install a `badCertificateCallback` that consults `TrustedHostsService`,
so favicon probes, downloads, and the SOCKS5 raw-socket secure tunnel
work for any host the user trusted in the webview.

#### Scenario: Favicon probe to a trusted self-signed host succeeds

**Given** `TrustedHostsService` has pinned `(self-signed.example.com, 443, sha256=...)`
**When** the favicon service issues `HttpClient.getUrl(https://self-signed.example.com/favicon.ico)`
**Then** the platform's TLS validation fails (self-signed)
**And** `badCertificateCallback` is invoked with the cert and host:port
**And** the SHA-256 of the cert's DER matches the pin
**And** the callback returns `true`
**And** the favicon is fetched

#### Scenario: Favicon probe to an unpinned self-signed host fails closed

**Given** no pin exists for `unknown-self-signed.example.com:443`
**When** an `HttpClient` makes a request to it
**Then** `badCertificateCallback` returns `false`
**And** the request throws `HandshakeException: CERTIFICATE_VERIFY_FAILED`
**And** the Dart caller (favicon service, etc.) treats the host as unreachable

---

### Requirement: TLS-005 - Cert rotation forces a re-prompt

Pins SHALL be keyed on the cert's SHA-256, not the host alone, so that a
rotated cert no longer matches the pin and the user is re-prompted.
This matches desktop-browser exception semantics: a self-signed site
swapping its cert mid-session is treated as a fresh, untrusted host.

#### Scenario: Self-signed cert rotates

**Given** `TrustedHostsService` has pinned `(self-signed.example.com, 443, sha256=A)`
**And** the host now serves a new self-signed cert with `sha256=B`
**When** the user navigates to `https://self-signed.example.com`
**Then** `TrustedHostsService.isTrusted` returns `false` (fingerprint mismatch)
**And** the user is re-prompted
**And** on approval the new fingerprint `B` replaces the old pin

---

### Requirement: TLS-006 - DER bytes missing → no pin

The prompt SHALL still appear when the platform's `SslCertificate` has
no DER bytes, but the user's decision MUST NOT be persisted (the pin
key requires a SHA-256 fingerprint). The dialog will reappear on the
next visit. Linux/WPE WebKit is the most common platform that omits the
DER payload.

#### Scenario: Platform doesn't surface DER bytes

**Given** the platform passes a `SslCertificate` whose `x509Certificate.encoded` is null or empty
**When** the user approves the prompt
**Then** `TrustedHostsService.fingerprintFromInappCertificate` returns `null`
**And** no pin is persisted
**And** a `[TLS/debug] user trusted cert ... but DER missing — cannot pin` log line is emitted
**And** the load proceeds for this session only

---

### Requirement: TLS-007 - Pins survive across app launches and roundtrip through settings export/import

Pins SHALL be persisted under SharedPreferences key `trustedHosts` and
round-tripped through the existing `kExportedAppPrefs` registry so
exporting and re-importing the settings file preserves them.

#### Scenario: Pin survives app restart

**Given** the user pinned `self-signed.example.com:443` in a previous session
**When** the app restarts and calls `TrustedHostsService.instance.initialize()`
**Then** the in-memory map is populated from SharedPreferences key `trustedHosts`
**And** the next navigation to that host returns `PROCEED` without a prompt

#### Scenario: Pin survives settings export → import

**Given** the user has one pinned host
**When** settings are exported via `SettingsBackupService` and then imported on a fresh install
**Then** the `trustedHosts` SharedPreferences value is restored
**And** `TrustedHostsService.reloadFromPrefs()` repopulates the in-memory map
**And** the pinned host loads without a prompt on the new install

---

### Requirement: TLS-008 - Spurious pins from the pre-fix release are wiped on first launch

The app SHALL run a one-shot `TrustedHostsService.clear()` on the first
launch after this fix, gated by SharedPreferences key
`trustedHostsResetForOsDefaultV1`. The initial release of the prompt
feature (commit `5ef1174`) intercepted every TLS handshake on iOS/macOS
and caused users to pin dozens of legitimate public CA leaf
fingerprints; the wipe gives the new OS-default-first flow a clean
slate. Subsequent launches MUST NOT re-run the wipe.

#### Scenario: One-shot reset runs once

**Given** `prefs.getBool('trustedHostsResetForOsDefaultV1')` is `false` or unset
**When** the app starts
**Then** `TrustedHostsService.instance.clear()` is invoked
**And** the pin list is emptied
**And** `trustedHostsResetForOsDefaultV1` is set to `true`

#### Scenario: One-shot reset does NOT run twice

**Given** `prefs.getBool('trustedHostsResetForOsDefaultV1')` is `true`
**When** the app starts
**Then** `TrustedHostsService.instance.clear()` is NOT invoked
**And** the user's legitimately-approved pins from after the migration are preserved

---

### Requirement: TLS-009 - Apple platforms skip the trust-prompt path entirely

The app SHALL NOT show the trust prompt on iOS or macOS, SHALL NOT
reload on SSL load errors, and SHALL NOT pin self-signed certs from
user input collected on those platforms. `_handleSslLoadError` returns
`false` immediately when `Platform.isIOS || Platform.isMacOS` so the
load fails with the OS's native error and no prompt-or-reload loop
runs. The pin store remains active for the Dart-side
`HttpClient.badCertificateCallback` path (TLS-004) — pins created on
Android/Linux or restored from a settings backup still apply to favicon
probes and downloads.

#### Scenario: Self-signed host on iOS/macOS fails closed without a prompt

**Given** the user is on iOS or macOS
**And** `https://self-signed.example.com` presents a self-signed cert
**When** the user navigates to it
**Then** `_handleServerTrust` returns `null`
**And** Apple Keychain rejects the chain
**And** `onReceivedError` fires with `SECURE_CONNECTION_FAILED`
**And** `_handleSslLoadError` returns `false` immediately
**And** no dialog is shown
**And** no pin is created
**And** the WebView shows the OS's native SSL failure state

#### Scenario: Public CA-signed sites still work on iOS/macOS

**Given** the user is on iOS or macOS
**And** the cert chain for `https://github.com` is trusted by Apple Keychain
**When** the user navigates to it
**Then** `_handleServerTrust` returns `null`
**And** the OS-default path accepts the chain
**And** the page loads without any TLS-related code firing

#### Scenario: Pre-existing pin still applies to Dart HttpClient on Apple platforms

**Given** a settings backup imported on iOS or macOS contains a pin for `self-signed.example.com:443`
**When** the favicon service issues `HttpClient.getUrl(https://self-signed.example.com/favicon.ico)`
**Then** `badCertificateCallback` consults `TrustedHostsService` (TLS-004 unchanged)
**And** the favicon request succeeds
**And** the WebView still cannot load the page (TLS-009 stands)

---

### Requirement: TLS-010 - Loopback sinkhole certs are cancelled without a prompt

The app SHALL NOT prompt the user for a self-signed `CN=localhost`
certificate served for a non-loopback host. A device-level DNS/ad
blocker (VPN-based blocker, hosts-file sinkhole, Private DNS) may
resolve a blocked tracker host to `127.0.0.1`, where a local responder
answers with a self-signed `localhost` cert. Because every such host
shares the same loopback cert, the post-failure trust callback would
otherwise stack one "Untrusted certificate" dialog per blocked
sub-resource on the page. The app SHALL `CANCEL` these loads silently
and SHALL NOT pin them. A genuine `https://localhost` dev server is
unaffected because the requested host then matches the cert identity.

#### Scenario: Tracker sinkholed to a localhost responder

**Given** a device DNS/ad blocker resolves `htlb.casalemedia.com` to a local responder presenting a self-signed cert whose `issuedTo.CName` / `issuedBy.CName` is `localhost`
**And** no pin exists for `htlb.casalemedia.com:443`
**When** the page loads it as a sub-resource and the OS rejects the cert
**Then** `_handleServerTrust` detects the loopback sinkhole cert
**And** returns `ServerTrustAuthResponseAction.CANCEL`
**And** no dialog is shown
**And** no pin is persisted
**And** a `[TLS] localhost sinkhole cert for ... — cancelling silently` log line is emitted

#### Scenario: Real local dev server still prompts

**Given** the user navigates to `https://localhost:8443` which presents a self-signed `CN=localhost` cert
**When** the OS rejects the chain and fires the trust callback
**Then** the requested host matches the loopback identity, so the sinkhole guard does not apply
**And** the normal Android/Linux prompt is shown (TLS-002)

---

## Implementation Notes

### Why `null` and not `ServerTrustAuthResponse()` for the defer path

`ServerTrustAuthResponse_` in
`flutter_inappwebview_platform_interface/lib/src/types/server_trust_auth_response.dart`:

```dart
ServerTrustAuthResponse_({
  this.action = ServerTrustAuthResponseAction_.CANCEL,
});
```

The generated `.g.dart` constructor falls through to `CANCEL` when
`action` is null. So `ServerTrustAuthResponse()` is equivalent to
`ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.CANCEL)`
— it silently cancels the handshake with no error event to the page.
The handler must return `null` (the Future's nullable element) to
trigger the upstream plugin's `nullSuccess` → `defaultBehaviour` →
`.performDefaultHandling` path on iOS/macOS.

This is an upstream API gap — the only "defer to platform default"
sentinel is `null`, which is not discoverable from the public Dart
constructor. See pichillilorenzo/flutter_inappwebview issues #1488,
#1669, #1673, #1770, #1924.

### Cached cert lookup in the post-failure handler

`_handleServerTrust` runs first (pre-evaluation on iOS/macOS) and
receives the cert via `challenge.protectionSpace.sslCertificate`.
`_handleSslLoadError` runs second (post-OS-rejection) via
`onReceivedError`, which carries no cert. The trust callback stashes
every cert it sees in `_sslCertificateCache[host:port]` so the error
handler can read it back for the prompt and for fingerprint comparison
against existing pins.

---

## Threat Model

| Threat                                          | Defended? | Mechanism                                       |
|-------------------------------------------------|-----------|-------------------------------------------------|
| MITM with a self-signed cert                    | Partial   | User is prompted; pin captures the moment-in-time fingerprint |
| MITM with a forged CA the user installed in Keychain | No        | By design — system trust store is honored       |
| Cert rotation MITM (attacker swaps cert mid-session) | Yes       | Pin mismatch re-prompts before any data leaks   |
| Backup file leaks pinned hosts                  | N/A       | Pins identify hosts the user accepted; not secret |
| User taps "Trust this site" on a phishing page  | No        | Out of scope — same threat model as desktop browsers |

---

## Files

### Created
- `lib/services/trusted_hosts_service.dart` — pin store + fingerprint helpers
- `lib/widgets/untrusted_cert_prompt.dart` — confirmation dialog
- `test/trusted_hosts_service_test.dart` — pure-Dart unit tests
- `test/outbound_http_trust_test.dart` — `HttpClient.badCertificateCallback` against a local self-signed HTTPS server
- `integration_test/tls_trust_prompt_test.dart` — drives WKWebView against a local self-signed HTTPS server

### Modified
- `lib/services/webview.dart` — `_handleServerTrust` defers on iOS/macOS; `_handleSslLoadError` post-failure prompt + reload; `onReceivedError` wires the SSL branch
- `lib/services/outbound_http.dart` — `_isTrustedBadCert` consults `TrustedHostsService`
- `lib/main.dart` — startup `TrustedHostsService.initialize()` + one-shot `clear()` migration
- `lib/screens/inappbrowser.dart` + per-site `WebViewConfig` wiring — propagates the `onUntrustedCertificate` callback so nested webviews use the same prompt
- `lib/settings/app_prefs.dart` — `trustedHosts` registered in `kExportedAppPrefs`

---

## Maintenance

When changing the TLS trust path:

1. **Never return `ServerTrustAuthResponse()` from `_handleServerTrust` for the defer-to-OS case.** Return `null`. See "Why `null`…" above.
2. **Test on iOS/macOS** — Android and Linux are post-failure and harder to regress; the fragile path is the iOS/macOS pre-evaluation deferral.
3. **Smoke test with badssl.com endpoints** for manual verification:
   - `https://self-signed.badssl.com/` — `SERVER_CERTIFICATE_UNTRUSTED`
   - `https://untrusted-root.badssl.com/` — unknown CA
   - `https://expired.badssl.com/` — `SERVER_CERTIFICATE_HAS_BAD_DATE`
   - `https://wrong.host.badssl.com/` — `SERVER_CERTIFICATE_BAD_IDENTITY`
4. **Run** `fvm flutter test test/trusted_hosts_service_test.dart test/outbound_http_trust_test.dart`. Integration tests run on a real device/simulator: `fvm flutter test integration_test/tls_trust_prompt_test.dart`.
5. If a new `WebResourceErrorType.SERVER_CERTIFICATE_*` variant lands in upstream `flutter_inappwebview_platform_interface`, add it to `_isSslError` in `lib/services/webview.dart`.
