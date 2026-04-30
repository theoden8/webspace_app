# Passkey / WebAuthn Support

## Purpose

WebAuthn/passkey authentication for sites loaded inside WebSpace's InAppWebView. On Android, a JS polyfill bridges `navigator.credentials.create()` / `.get()` calls to the Android Credential Manager API via a flutter_inappwebview JavaScript handler and a platform channel. iOS support is pending.

## Requirements

### Requirement: PK-001 - Passkey Feature Detection

The app SHALL mock `PublicKeyCredential` and its static detection methods on Android so sites detect passkey support.

#### Scenario: Site checks for passkey availability

**Given** a website calls `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`
**When** the polyfill is active on Android
**Then** the method resolves to `true`
**And** the site shows passkey sign-in options

---

### Requirement: PK-002 - Passkey Creation

The app SHALL bridge `navigator.credentials.create({ publicKey })` to the Android Credential Manager on Android 9+.

#### Scenario: Create a passkey

**Given** a site calls `navigator.credentials.create()` with a `publicKey` option
**When** the polyfill intercepts the call
**Then** native WebView WebAuthn is tried first
**And** if native fails, the Credential Manager bridge is used as fallback
**And** the site receives a `PublicKeyCredential` response or an appropriate error

---

### Requirement: PK-003 - Passkey Authentication

The app SHALL bridge `navigator.credentials.get({ publicKey })` to the Android Credential Manager on Android 9+.

#### Scenario: Sign in with passkey

**Given** a site calls `navigator.credentials.get()` with a `publicKey` option
**When** the polyfill intercepts the call
**Then** native WebView WebAuthn is tried first
**And** if native fails, the Credential Manager bridge is used as fallback

---

### Requirement: PK-004 - Non-PublicKey Passthrough

The polyfill SHALL NOT intercept credential requests that do not use the `publicKey` option.

#### Scenario: Password credential request

**Given** a site calls `navigator.credentials.get()` without `publicKey`
**When** the call is evaluated
**Then** the original `navigator.credentials.get()` is called unmodified

---

### Requirement: PK-005 - Polyfill Re-injection

The WebAuthn polyfill SHALL be re-injected on every page navigation.

#### Scenario: Navigate to a new page

**Given** the user navigates from page A to page B
**When** page B loads
**Then** the polyfill is active on page B

## Architecture

### JS Polyfill (`_webAuthnPolyfillScript` in `lib/services/webview.dart`)

Injected at `DOCUMENT_START` on Android. The polyfill:

1. **Detection methods** (no guard -- always set):
   - `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` -> `true`
   - `PublicKeyCredential.isConditionalMediationAvailable()` -> `false`

2. **create/get overrides** (guarded by `__webauthnPolyfilled` flag):
   - Saves original `navigator.credentials.create` / `.get`
   - On `create({ publicKey })` or `get({ publicKey })`:
     - Tries the original (native) method first
     - On failure, serializes the `PublicKeyCredentialCreationOptions` / `RequestOptions` (converting ArrayBuffers to Base64URL) and calls `window.flutter_inappwebview.callHandler('webauthn', action, requestJson, origin)`
     - Deserializes the JSON response back into a `PublicKeyCredential`-shaped object with ArrayBuffer fields

### Native Handler (`WebAuthnHandler.kt`)

- `setupWebAuthn()`: Walks the Activity's view hierarchy looking for `android.webkit.WebView` instances. For each, calls `WebSettingsCompat.setWebAuthenticationSupport(settings, WEB_AUTHENTICATION_SUPPORT_FOR_APP)` if `WebViewFeature.WEB_AUTHENTICATION` is supported.
- `handleCreate(requestJson, origin, callback)`: Creates a `CreatePublicKeyCredentialRequest` and calls `CredentialManager.createCredentialAsync`. Returns the registration response JSON via the callback.
- `handleGet(requestJson, origin, callback)`: Creates a `GetPublicKeyCredentialOption` wrapped in `GetCredentialRequest` and calls `CredentialManager.getCredentialAsync`. Returns the authentication response JSON.

Uses callback-based async (`CredentialManagerCallback`), not Kotlin coroutines.

### Platform Channel (`MainActivity.kt`)

Channel: `org.codeberg.theoden8.webspace/webauthn`

Methods:
- `setupWebAuthn` -> `String` (diagnostic info)
- `create` -> `String` (response JSON), args: `requestJson`, `origin`
- `get` -> `String` (response JSON), args: `requestJson`, `origin`

### Dart Side (`lib/services/webview.dart`)

- `_webAuthnChannel`: `MethodChannel('org.codeberg.theoden8.webspace/webauthn')`
- In `onWebViewCreated`: registers `'webauthn'` JS handler that forwards to the platform channel, then calls `setupWebAuthn` via `Future.microtask`.
- In `onLoadStart`: re-injects the polyfill script alongside the ClearURLs and content-blocker early scripts.
- In `createWebView` user scripts: adds the polyfill as a `UserScript` at `AT_DOCUMENT_START`.

## Known Limitations

### FOR_BROWSER crashes

`WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_BROWSER` causes a crash on most devices because it requires a Digital Asset Links (DAL) file at `/.well-known/assetlinks.json` on the site's domain that declares the app's signing certificate. Since WebSpace loads arbitrary user-chosen sites, FOR_BROWSER is not viable.

### CREDENTIAL_MANAGER_SET_ORIGIN is system-only

The `CREDENTIAL_MANAGER_SET_ORIGIN` permission required by `CreatePublicKeyCredentialRequest(requestJson, origin)` (the two-arg constructor) is a signature-level permission granted only to system apps (e.g. Chrome, GMS). Third-party apps cannot set the origin, so the Credential Manager uses the app's package identity instead.

### FOR_APP requires DAL

`WEB_AUTHENTICATION_SUPPORT_FOR_APP` tells the System WebView to route WebAuthn requests to the embedding app. For this to work end-to-end with a relying party, the RP's `/.well-known/assetlinks.json` must list the app's package name and signing certificate hash. Without a DAL entry, the RP server rejects the attestation/assertion because the origin doesn't match. This limits passkey support to sites that have explicitly registered the WebSpace app -- which in practice means it works as a proof-of-concept but won't work on arbitrary sites until they add WebSpace to their DAL.

### iOS pending

iOS WKWebView has no equivalent of `setWebAuthenticationSupport`. ASWebAuthenticationSession provides OAuth flows but not raw WebAuthn. Passkey support on iOS requires a different approach (possibly an Authentication Services extension) and is not yet implemented.

## Files

| File | Role |
|------|------|
| `android/app/build.gradle` | Dependencies: `androidx.webkit:webkit:1.14.0`, `androidx.credentials:credentials:1.5.0`, `credentials-play-services-auth:1.5.0` |
| `android/app/src/main/kotlin/.../WebAuthnHandler.kt` | Native WebAuthn handler (Credential Manager + WebSettingsCompat) |
| `android/app/src/main/kotlin/.../MainActivity.kt` | Platform channel registration |
| `lib/services/webview.dart` | JS polyfill, handler registration, re-injection |

## Manual Test

### Given
- Android device with System WebView >= 110 and Google Play Services
- A site that supports passkeys (e.g. webauthn.io, passkeys.io)

### When
1. Add the site to WebSpace
2. Navigate to the passkey registration / login page
3. Tap "Register" or "Sign in with passkey"

### Then
- The Android Credential Manager UI appears
- On successful authentication, the site proceeds as if passkey auth succeeded
- Console logs show `[WebAuthn polyfill]` messages indicating the bridge path
