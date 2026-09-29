# passkey-support Specification

## Purpose
Let a site sign the user in with a passkey on Android, the way a browser does:
the site's own origin is asserted to Android's Credential Manager, and the
passkey app the user chose (Bitwarden, Keyguard, a test provider) answers.

Android System WebView ships WebAuthn off. Its own switch has two modes, and
neither fits an app that shows arbitrary sites: `FOR_APP` asserts the app's
identity, so it works only for sites whose Digital Asset Links name the app,
and `FOR_BROWSER` needs a recent WebView and hands every decision to the
engine. So the app bridges WebAuthn itself. A page-side shim hands
`navigator.credentials.create/get({publicKey})` to Dart, Dart decides whether
the calling document may ask and for which relying party, builds the
clientDataJSON a browser would, and the native plugin asks Credential Manager
with that origin and the JSON's SHA-256.

Asserting an origin needs `android.permission.CREDENTIAL_MANAGER_SET_ORIGIN`.
Its protection level is `normal` (AOSP `core/res/AndroidManifest.xml`), so
declaring it is enough; an earlier attempt that did not declare it saw a
SecurityException and concluded, wrongly, that it was signature-level.

The real gate is the credential provider, not the OS. A provider hands an
origin back through `CallingAppInfo.getOrigin(allowlist)` only for callers on
its privileged-browser allowlist, and decides for itself what to do with an
unlisted one. The app does not control that; see Known Limitations.

## Requirements

### Requirement: PASSKEY-001 — Access is Android-only, off for archives

Passkeys SHALL be offered on Android to every site except an archive-tier one:
the system passkey sheet is OS-level UI naming the relying party, and a created
passkey lives in the provider, outside the archive's keyspace (ARCH-006).
`WebViewModel.effectivePasskeysEnabled` is the one reading of that rule, and
nested webviews receive it through `launchUrl`.

There is no switch. Without the shim a site sees the WebView's default, no
`PublicKeyCredential` at all, and a sign-in that probes for passkeys without
checking the interface exists throws a TypeError and stalls: target.com's
Continue did nothing (issue #567). With the shim, a device that cannot answer
reads as one without a platform authenticator (PASSKEY-002), which sites
handle.

A webview whose `WebViewConfig.passkeys` is null SHALL get neither the shim
nor the handlers, which leaves the WebView's default: no WebAuthn.

#### Scenario: Any site outside an archive

**Given** an Android site that is not in an archive
**When** its page loads
**Then** `PublicKeyCredential` is installed by the shim
**And** the passkey handlers are registered on the webview

#### Scenario: A sign-in that probes without checking the interface

**Given** a sign-in page that calls
`window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`
without checking that `PublicKeyCredential` exists
**When** the user submits their email
**Then** the call resolves instead of throwing
**And** the sign-in continues

#### Scenario: Archive-tier site

**Given** the site is in an open archive
**When** the site, or a nested webview it opens, loads a page
**Then** no passkey shim or handler is installed

---

### Requirement: PASSKEY-002 — Android 14 Credential Manager, no Play Services

The bridge SHALL call Credential Manager through `androidx.credentials` on API
34 and later only, and SHALL NOT depend on Google Play Services (no
`credentials-play-services-auth`). Below API 34, or where the device lacks
`android.software.credentials`, or where the origin permission is not granted,
`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` SHALL
resolve false and a ceremony SHALL reject with NotSupportedError without
calling the native side.

The manifest SHALL declare `CREDENTIAL_MANAGER_SET_ORIGIN` and
`CREDENTIAL_MANAGER_QUERY_CANDIDATE_CREDENTIALS`.

#### Scenario: API 33

**Given** an API 33 device
**When** a page calls `navigator.credentials.create({publicKey})`
**Then** it rejects with NotSupportedError
**And** Credential Manager is not called

---

### Requirement: PASSKEY-003 — The shim installs WebAuthn and routes public-key requests

In a secure context the shim SHALL install `PublicKeyCredential`,
`AuthenticatorResponse`, `AuthenticatorAttestationResponse` and
`AuthenticatorAssertionResponse` (illegal constructors, prototype getters,
[SameObject] ArrayBuffers), and replace `CredentialsContainer.prototype.create`
and `get`. A request with `publicKey` SHALL be serialized to WebAuthn-JSON
(every BufferSource as unpadded base64url, extensions included) and handed to
the `webauthnRequest` handler; a request without it SHALL reach the engine's
own method unchanged.

`mediation: "conditional"` SHALL reject with NotSupportedError, and
`isConditionalMediationAvailable()` SHALL resolve false. An `AbortSignal` SHALL
reject the promise with its reason at once and cancel the native ceremony.

The page never names the origin: nothing it passes is read as one (PASSKEY-004).

#### Scenario: Registration

**Given** a page on an https origin
**When** it calls `navigator.credentials.create({publicKey: ...})` and the provider answers
**Then** it receives a `PublicKeyCredential` whose `response` is an `AuthenticatorAttestationResponse`
**And** `response.clientDataJSON` is the one PASSKEY-006 built

#### Scenario: Password credential request

**Given** a page calls `navigator.credentials.get({password: true})`
**Then** the engine's own `get` runs and the bridge is not called

---

### Requirement: PASSKEY-004 — The origin is the calling frame's, and the site is on screen

The origin asserted to Credential Manager SHALL be the frame origin the
bridge's preamble captured before page script ran (`JavaScriptHandlerFunctionData.origin`),
serialized per RFC 6454. A main frame SHALL also match the document the webview
shows (`getUrl()`), so a request racing a navigation is refused. A subframe
SHALL be refused unless it is same-origin with the top document: Permissions
Policy delegation (`publickey-credentials-create/get`) is not implemented, so
every cross-origin frame is refused with NotAllowedError.

The origin SHALL be potentially trustworthy: https, or http to loopback.

A site that is not the one on screen SHALL be refused with NotAllowedError
("The document is not focused."): the passkey sheet names only the relying
party and would read as the visible site's request.

#### Scenario: A page names another origin

**Given** a page on `https://evil.test`
**When** it passes any value it likes to the bridge
**Then** Credential Manager is told `https://evil.test`

#### Scenario: Cross-origin iframe

**Given** a page on `https://a.test` embedding `https://b.test`
**When** the iframe calls `navigator.credentials.get({publicKey})`
**Then** it rejects with NotAllowedError and nothing reaches Credential Manager

---

### Requirement: PASSKEY-005 — The relying party belongs to the origin

The rp id (`rp.id` for create, `rpId` for get, defaulting to the origin's host)
SHALL equal the origin's host or be a registrable domain suffix of it, read
through `getBaseDomain`, which errs long on unknown suffixes; an IP origin
SHALL only name itself. Otherwise the request SHALL reject with SecurityError.
Providers are told to skip this check for privileged callers, so it lives here.

#### Scenario: Public suffix

**Given** a page on `https://victim.github.io`
**When** it asks for rpId `github.io`
**Then** it rejects with SecurityError

---

### Requirement: PASSKEY-006 — clientDataJSON is the app's, and one ceremony runs at a time

The app SHALL build clientDataJSON in the WebAuthn L3 serialization
(`{"type":..,"challenge":..,"origin":..,"crossOrigin":false}`, CCDToString
escaping, the challenge re-encoded as unpadded base64url) and pass its SHA-256
to Credential Manager as `clientDataHash` with the origin. At most one ceremony
SHALL run across all webviews; a second is refused with NotAllowedError ("A
request is already pending.").

#### Scenario: The provider signs the app's clientDataJSON

**Given** a page on `http://localhost:8443` registering with rp id `localhost`
**When** the provider signs over the `clientDataHash` it was given
**Then** the relying party verifies the clientDataJSON the page received against that signature
**And** its origin is `http://localhost:8443`

#### Scenario: Two sites at once

**Given** a ceremony is running for one webview
**When** another webview starts one
**Then** the second rejects with NotAllowedError and the first is unaffected

---

### Requirement: PASSKEY-007 — The provider's answer is completed, not trusted

`response.clientDataJSON` in the provider's JSON SHALL be replaced with the
app's: providers given a hash return a placeholder, or JSON of their own that
does not hash to what they signed. A registration missing `authenticatorData`
SHALL have it filled from the attestation object. A response whose
`authenticatorData` does not start with SHA-256 of the rp id, or that lacks
the fields its ceremony needs, SHALL reject with NotReadableError rather than
reach the page.

#### Scenario: A placeholder clientDataJSON

**Given** the provider returns `clientDataJSON` = base64url(`{}`)
**When** the bridge completes the response
**Then** the page receives the app's clientDataJSON instead

#### Scenario: A credential for another relying party

**Given** the page asked for rp id `example.com`
**When** the provider's assertion carries the rpIdHash of `evil.test`
**Then** the page gets NotReadableError and no credential

---

### Requirement: PASSKEY-008 — Errors read as a browser's

Cancelling, having no passkey and having nowhere to save one SHALL all reject
with NotAllowedError, so a page cannot tell them apart. An excluded credential
SHALL reject with InvalidStateError. A missing origin permission (the
framework's synchronous SecurityException), an unsupported device or a request
the library refuses SHALL reject with NotSupportedError; anything else with
NotReadableError. Messages are fixed strings, never the provider's.

#### Scenario: The provider refuses the app

**Given** a provider that does not trust the app with an origin and answers NotAllowedError
**When** the page registers
**Then** it rejects with NotAllowedError

#### Scenario: A build without the origin permission

**Given** the framework throws SecurityException from `createCredential`
**When** the page registers
**Then** it rejects with NotSupportedError and the app keeps running

---

### Requirement: PASSKEY-009 — Nothing about the site reaches logcat

The native plugin SHALL NOT log origins, rp ids or request bodies; Dart logs
only the operation and the DOMException name.

#### Scenario: A ceremony completes

**Given** a page on `https://login.example.com` signs in
**Then** no logcat line from the app names `login.example.com`

---

### Requirement: PASSKEY-010 — The WebView's own WebAuthn is a comparison, not a path

`PasskeyBackend.webView` sets the WebView's `WEB_AUTHENTICATION_SUPPORT_FOR_BROWSER`
instead of installing the bridge. It is reachable from tests only, because
advertising the feature does not mean an authenticator is behind it. On the
gate's emulator (API 35 AOSP image, `com.android.webview` 124.0.6367.219,
three runs on 2026-09-28) the WebView advertises `WEB_AUTHENTICATION`, reads
back FOR_BROWSER (2) after it is set, and does not crash with the origin
permission declared, yet `isUserVerifyingPlatformAuthenticatorAvailable()`
resolves false and `create()` rejects with NotSupportedError "Not implemented".
The bridge answers the same page on the same WebView.

#### Scenario: A WebView without WEB_AUTHENTICATION

**Given** the WebView does not advertise `WEB_AUTHENTICATION`
**When** a test selects the WebView backend
**Then** the setting is not applied and the test reports it as unsupported

#### Scenario: A WebView that advertises the switch with nothing behind it

**Given** the gate's AOSP WebView, which advertises `WEB_AUTHENTICATION`
**When** the `webview` phase sets FOR_BROWSER and the page calls `create()`
**Then** the phase reports the page's outcome and the gate records it as a NOTE, never a FAIL

---

### Requirement: PASSKEY-011 — What providers do with the app is their call

The app SHALL NOT attempt to widen what a provider accepts. Getting onto a
provider's allowlist is a submission to that provider, with the package name
and every signing certificate of every build that ships (F-Droid and Play sign
with different keys).

#### Scenario: A provider not listing the app

**Given** a provider that answers only callers on its allowlist
**When** the app asks it for a passkey with an origin
**Then** the provider's refusal reaches the page as NotAllowedError

---

### Requirement: PASSKEY-012 — Emulator gate

`scripts/run_android_passkey_tests.sh` SHALL run the bridge on an API 35 AOSP
emulator against `@simplewebauthn/server` and a test credential provider that
checks the caller against an allowlist, and grade each case from observed
evidence (the RP's results, the provider's logcat, `dumpsys package`):

| Gate | Evidence |
|---|---|
| G0 | `android.software.credentials`, `credential_service` names the test provider, `adb reverse`, the page is a secure context with `PublicKeyCredential` and a platform authenticator |
| G1 | both permissions `granted=true` |
| G2 | the RP verifies a registration whose clientDataJSON origin is `http://localhost:8443`, and the provider logged that origin |
| G3 | two sign-ins verify and the signature counter rises |
| G4 | with the app off the provider's allowlist, the page gets NotAllowedError, the provider logged its refusal, and the app did not crash |
| G8 | a second webview signs in with the passkey the first one created |

The permission-less build and the API 33 device are JVM-tested instead
(`PasskeyCeremoniesTest`): the SecurityException is caught where the framework
throws it, and below API 34 the native call is not made.

#### Scenario: CI run

**Given** the Android job's passkey gate step on an API 35 AOSP emulator
**When** `scripts/run_android_passkey_tests.sh` finishes
**Then** it prints PASS or FAIL per gate with the evidence line, and exits non-zero on any FAIL

## Architecture

| Piece | Where |
|---|---|
| Shim | `lib/services/passkey_shim.dart` (`test/js/passkey_shim.test.js`) |
| Origin, rpId, clientDataJSON, response completion, error map | `lib/services/passkey_engine.dart` (`test/passkey_engine_test.dart`) |
| Handlers `webauthnStatus` / `webauthnRequest` / `webauthnCancel` | `WebViewFactory._registerPageHandlers` in `lib/services/webview.dart` (`test/js/page_bridge_authority.test.js`) |
| Channel `org.codeberg.theoden8.webspace/passkey` | `lib/services/passkey_native.dart`, `android/.../PasskeyPlugin.kt` (`PasskeyCeremoniesTest.kt`) |
| Gate | `scripts/run_android_passkey_tests.sh`, `integration_test/passkey_test.dart`, `tool/passkey_gate/` |

## Known Limitations

- **Providers decide.** Checked against their sources on 2026-09-28:
  - Bitwarden 2025.10.0 and later: an unlisted browser gets an "Unrecognized
    browser" prompt with Trust, remembered per package and certificate.
  - Keyguard: "Grant the privilege and continue".
  - KeePassDX: the F-Droid build ships no allowlist and only offers to trust
    apps that handle https links, which this app does not declare.
  - Proton Pass, AliasVault and Google Password Manager: Google's list only
    (https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json), which
    this app is not on.
- **Bitwarden's community list** would remove the prompt. A known package with
  an unknown certificate hard-fails there with no prompt, so an entry must list
  both the F-Droid certificate
  (`4B:2B:82:5D:DD:A5:38:D0:72:2C:61:31:D1:C9:91:2F:E4:50:79:08:F5:B7:39:79:85:A0:97:83:CF:4F:B3:92`)
  and the Play one.
- No conditional mediation (passkey autofill), no hybrid or security-key
  transports beyond what the provider offers, no Permissions Policy delegation
  to cross-origin frames.
- iOS and macOS: not implemented.
