# Site Settings QR Specification

## Purpose

Share a site's per-site configuration out-of-band via a QR code (or its
underlying `webspace://qr/site/v1/<payload>` URL) so a recipient can
recreate the same site on their device with the same proxy address,
language, geo, blocking flags, fullscreen mode, and so on — without ever
moving secrets, cookies, user scripts, or imported HTML between
devices. The QR is a *configuration* exchange, not a *session* or
*content* exchange.

This spec is the partner of
[`proxy-password-secure-storage`](../proxy-password-secure-storage/spec.md):
both rely on the contract that `UserProxySettings.toJson` strips the
password by default, so any caller serialising a `WebViewModel` for
external use (backup file, QR, anything else) gets a sanitised payload
for free.

## Status

- **Status**: Completed
- **Wire format version**: `v1`

---

## Threat Model

| Threat                                           | Defended? | Mechanism |
|--------------------------------------------------|-----------|-----------|
| Sender leaks proxy password via QR               | Yes       | `UserProxySettings.toJson` omits password by default; codec relies on the default `toJson` |
| Sender leaks session cookies (incl. `isSecure`)  | Yes       | `cookies` is in `excludedKeys`; never written to the payload |
| Sender leaks user-supplied JavaScript            | Yes       | `userScripts` and `enabledGlobalScriptIds` are in `excludedKeys` |
| Sender leaks user's site identity / browse state | Yes       | `siteId`, `currentUrl`, `pageTitle` are in `excludedKeys`; receiver mints a fresh `siteId` |
| Hostile sender smuggles a key past the strip     | Yes       | Receiver re-applies the `includedKeys` whitelist on decode (defence in depth) |
| Hostile sender supplies wrong-typed values       | No        | Codec only type-checks `initUrl`; other fields are pass-through. A crafted payload that decodes but has e.g. `spoofLatitude: "x"` propagates through `WebViewModel.fromJson` and throws `TypeError` in `_addSite`. See QR-007 for the gap. |
| Future sender ships a `vN > 1` payload to v1 app | Yes       | Receiver returns `null` from decode when `version > currentVersion` |

---

## Requirements

### Requirement: QR-001 - Wire Format

The QR payload SHALL be a `webspace://qr/site/v<N>/<base64url>` URL
where `<base64url>` is gzip-compressed UTF-8 JSON of a
[QR-002](#requirement-qr-002---shareable-subset)-conformant map.

#### Scenario: Encoded URL shape

**Given** a shareable subset map
**When** `SiteSettingsQrCodec.encode` is called
**Then** the result starts with `webspace://qr/site/v1/`
**And** the suffix is the base64url-encoded gzip of the JSON
**And** base64url padding (`=`) is stripped on encode

#### Scenario: Padding restored on decode

**Given** an encoded URL with stripped padding
**When** `SiteSettingsQrCodec.decode` is called
**Then** the decoder reapplies `=` padding to a multiple of 4 before
base64url-decoding the payload

#### Scenario: looksLikeQrPayload is permissive on version

**Given** an input string whose prefix matches `webspace://qr/site/v<any-int>/<non-empty>`
**When** `SiteSettingsQrCodec.looksLikeQrPayload` is called
**Then** it returns true regardless of whether the inner payload would
successfully decode — this is the cheap pre-flight signal used by
external-scheme handlers, not a validity check.

---

### Requirement: QR-002 - Shareable Subset

The codec SHALL whitelist exactly the keys in `includedKeys` and SHALL
strip everything else. The whitelist is the single source of truth on
both encode and decode.

#### Scenario: Encode strips everything outside the whitelist

**Given** a `WebViewModel.toJson()` map that contains all model keys
**When** `SiteSettingsQrCodec.shareableSubset` is called
**Then** the result contains exactly the keys in `includedKeys` that
were present in the input
**And** no `excludedKeys` entry survives

#### Scenario: Decode re-applies the whitelist

**Given** an encoded payload whose JSON contains keys outside
`includedKeys` (e.g., a hostile sender added `cookies` or `siteId` back
into the JSON)
**When** `SiteSettingsQrCodec.decode` is called
**Then** the returned map contains only keys from `includedKeys` —
the smuggled keys are dropped before the result reaches the caller.

#### Scenario: Drift detection in test suite

**Given** any new field added to `WebViewModel.toJson`
**When** `test/site_settings_qr_codec_test.dart` runs
**Then** the test fails unless the new key is classified into either
`includedKeys` or `excludedKeys`. This forces every per-site field to
be reviewed for shareability before it can ship.

---

### Requirement: QR-003 - Excluded Keys (Secrets, Identity, Session, Content)

The following SHALL never appear in an encoded payload:

| Key                       | Reason |
|---------------------------|--------|
| `siteId`                  | Receiver mints a fresh ID; sharing it would collide with a random device-local ID space |
| `currentUrl`, `pageTitle` | Runtime browse state, not configuration |
| `cookies`                 | Includes `isSecure=true` cookies; carrying any cookies cross-device is a session-export risk |
| `userScripts`             | User-supplied JavaScript — code, not config |
| `enabledGlobalScriptIds`  | Refers to receiver-local script IDs that don't exist on the source |
| `blockedCookies`          | Receiver-local denylist, not portable |
| `proxySettings.password`  | Stripped by `UserProxySettings.toJson` per [`proxy-password-secure-storage`](../proxy-password-secure-storage/spec.md) (PWD-005) |

#### Scenario: Proxy password never appears in the payload

**Given** a site whose `UserProxySettings.password` is `"super-secret"`
**When** `SiteSettingsQrCodec.encode(SiteSettingsQrCodec.shareableSubset(model.toJson()))` is called
**And** the result is base64url-decoded and gunzipped to its inner JSON
string
**Then** the inner JSON does not contain the literal string `"super-secret"`
**And** the inner JSON does not contain the substring `password`

This is the PWD-005-equivalent assertion for the QR path; the codec
test enforces it.

#### Scenario: Cookies never appear in the payload

**Given** a site with one or more cookies (any flags)
**When** the same encode-decode-grep round-trip is performed
**Then** the inner JSON does not contain the substring `"cookies"`

#### Scenario: User scripts never appear in the payload

**Given** a site with one or more `UserScriptConfig` entries
**When** the same round-trip is performed
**Then** the inner JSON does not contain the substring `"userScripts"`

---

### Requirement: QR-004 - Decode Validation

The decoder SHALL return `null` (not throw) for any malformed input.
The receiver UI relies on `null` to mean "show user-friendly error" —
exceptions would propagate as unhandled future errors.

#### Scenario: Malformed prefix

**Given** an input that does not start with `webspace://qr/site/v`
**When** `decode` is called
**Then** the result is `null`

#### Scenario: Forward-incompatible version

**Given** a payload whose version segment is greater than `currentVersion`
**When** `decode` is called
**Then** the result is `null` (the receiver is older than the sender;
fail closed rather than try to interpret unknown fields)

#### Scenario: Malformed base64 / gzip / JSON

**Given** a payload where any of (a) base64url decoding, (b) gzip
inflation, or (c) JSON parsing throws
**When** `decode` is called
**Then** the exception is caught and the result is `null`

#### Scenario: Missing or empty initUrl

**Given** a successfully parsed JSON that lacks `initUrl`, or whose
`initUrl` is an empty string, or whose `initUrl` is not a string
**When** `decode` is called
**Then** the result is `null` — `initUrl` is the only field the codec
type-checks; without it the resulting site has no URL to load

---

### Requirement: QR-005 - Sender UI (Share QR)

Per-site settings SHALL expose a "Share QR" action that renders the
encoded payload as a QR code visual and offers Copy and Share actions.

#### Scenario: Share QR shown for fetchable URLs

**Given** the user opens per-site settings for a site whose `initUrl`
starts with `http://` or `https://`
**When** the screen builds
**Then** a "Share QR" button is visible

#### Scenario: Share QR hidden for file-import sites

**Given** the user opens per-site settings for a site whose `initUrl`
starts with `file://`
**When** the screen builds
**Then** no "Share QR" button is visible.

A `file:///<filename>` handle is synthetic — the actual HTML lives in
the source device's `HtmlImportStorage` (per
[`file-import-sites`](../file-import-sites/spec.md)) and never rides
the QR. Sharing the handle alone would yield an unloadable site on the
receiver, so the action is suppressed.

#### Scenario: Copy closes the dialog

**Given** the Share QR dialog is open
**When** the user taps "Copy"
**Then** the encoded URL is written to the clipboard
**And** the dialog pops
**And** a "Copied to clipboard" snackbar appears via
`rootScaffoldMessengerKey` (so it survives the pop and isn't tied to
the dialog's BuildContext)

#### Scenario: Share closes the dialog

**Given** the Share QR dialog is open
**When** the user taps "Share"
**Then** the encoded URL is handed to the OS share sheet via
`SharePlus.instance.share`
**And** the dialog pops

#### Scenario: QR visual sized to avoid intrinsic-dimension errors

**Given** the Share QR dialog is open
**When** Flutter's `AlertDialog` queries the content's intrinsic width
**Then** the query terminates at the `SizedBox(width: 240, height: 240)`
wrapping `QrImageView`, never reaching `QrImageView`'s internal
`LayoutBuilder` (which would throw "LayoutBuilder does not support
returning intrinsic dimensions").

---

### Requirement: QR-006 - Receiver UI (Add Site)

The Add Site screen SHALL offer a QR-scan / QR-paste path that creates
a new site from a decoded payload.

#### Scenario: QR icon on the URL field

**Given** the user opens "Add new site"
**When** the screen builds
**Then** the URL `TextField`'s suffix icon is `Icons.qr_code_scanner`
with tooltip "Add from QR code"

#### Scenario: Scanner on Android/iOS, paste-fallback elsewhere

**Given** the user taps the QR icon
**When** the platform is Android or iOS
**Then** the in-app camera scanner (`SiteSettingsQrScannerScreen`,
flutter_zxing) is pushed first; if the user backs out, the paste
dialog is shown
**And** when the platform is Linux/macOS/Windows/web the paste dialog
is shown directly (no camera path).

#### Scenario: Paste dialog reports decode failures inline

**Given** the paste dialog is open
**When** the user taps "Apply" with a value that `decode` rejects
**Then** the dialog stays open
**And** the TextField shows "Not a valid WebSpace site-settings QR."
under it

#### Scenario: TextEditingController outlives the dialog animation

**Given** the paste dialog has just been popped
**When** the dialog's exit animation runs to completion
**Then** the `TextEditingController` has not been disposed yet — it
lives in `_PasteDialogState` so `State.dispose` runs only after the
widget is fully removed from the tree, avoiding the "TextEditingController
was used after being disposed" assertion that the previous
`StatefulBuilder`-based implementation hit.

#### Scenario: Successful decode creates a fresh site

**Given** the user pastes (or scans) a valid `webspace://qr/site/v1/...`
URL and taps Apply
**When** `_addSite` receives the result map containing
`{'qrSettings': decoded}`
**Then** a new `WebViewModel` is built via
`WebViewModel.fromJson(SiteSettingsQrCodec.hydrateForFromJson(decoded), stateSetter)`
**And** the new model has a freshly-minted `siteId` (the QR payload
does not carry one, so the model's auto-generation kicks in)
**And** the new model's `cookies`, `userScripts`, and
`enabledGlobalScriptIds` are empty (the hydrate helper supplies
`cookies: []`; the others are absent from the QR and stay null/empty)
**And** the model's `proxySettings.password` is null (the QR didn't
carry it; the receiver must enter it manually if the proxy needs auth)

#### Scenario: Page title fallback when QR's name is empty

**Given** the QR payload's `name` is empty or null
**When** `_addSite` consumes the `qrSettings`
**Then** the receiver issues `getPageTitle(initUrl)` and uses the
returned title for both `name` and `pageTitle` if non-empty

#### Scenario: Page title kept when QR carries a name

**Given** the QR payload's `name` is non-empty
**When** `_addSite` consumes the `qrSettings`
**Then** no `getPageTitle` HTTP fetch happens
**And** the model's `pageTitle` is set to its `name`

---

### Requirement: QR-007 - Type Validation Gap (Known Limitation)

The codec SHALL reject only `initUrl` mismatches at decode time. Other
fields are pass-through. A QR generated by another WebSpace install
cannot trigger a type error: `toJson` always emits the right types.
The risk is a hand-crafted hostile QR.

**Out of scope for v1**: per-field schema validation. If this becomes
a real issue (user reports / fuzzing campaigns), the fix is to tighten
`SiteSettingsQrCodec.decode` to type-check every included key against
the model's expected types before returning the map. That should
happen in a follow-up spec; for now this requirement documents the
gap so a future change can't regress on it accidentally.

#### Scenario: Wrongly-typed numeric field reaches fromJson

**Given** a `webspace://qr/site/v1/...` URL whose decoded JSON conforms
to QR-001 / QR-004 (well-formed prefix, gzip, JSON, non-empty `initUrl`)
but contains, e.g., `"spoofLatitude": "abc"` (string where a `num?` is
expected)
**When** `_addSite` consumes the result and calls
`WebViewModel.fromJson(SiteSettingsQrCodec.hydrateForFromJson(decoded), stateSetter)`
**Then** the `as num?` cast in `fromJson` throws a `TypeError`
**And** the error is not caught locally — it surfaces as an unhandled
async error rather than as a user-visible snackbar. Closing this gap
is the explicit follow-up.

#### Scenario: Wrongly-typed enum-like string falls back silently

**Given** a decoded payload whose `locationMode` or `webRtcPolicy`
string does not match any enum value name
**When** `WebViewModel.fromJson` reads the field
**Then** the field falls back to its default (`LocationMode.off` /
`WebRtcPolicy.defaultPolicy`) instead of throwing — the
`firstWhere(orElse: ...)` shape in `fromJson` already handles this
class of mismatch gracefully, distinct from the typed-cast case above.

---

## Data Model

No new persisted fields. The QR is a transient JSON projection of the
existing `WebViewModel` config surface. Two helper sets define the
projection:

- `SiteSettingsQrCodec.includedKeys` — the whitelist that rides the wire
- `SiteSettingsQrCodec.excludedKeys` — keys deliberately stripped, used
  by the drift test to ensure every model key is classified

`hydrateForFromJson` is the receiver-side helper that pads the stripped
subset with the empty placeholders `WebViewModel.fromJson` requires
(currently just `cookies: []`).

---

## Files

### Added
- `lib/services/site_settings_qr_codec.dart` — encode/decode, whitelist,
  hydrate helper, `looksLikeQrPayload` signal
- `lib/screens/site_settings_qr.dart` — Share QR dialog (sender),
  paste-fallback dialog (receiver), platform-aware apply entry point
- `lib/screens/site_settings_qr_scanner.dart` — flutter_zxing camera
  scanner screen (Android/iOS only)
- `test/site_settings_qr_codec_test.dart` — codec round-trip + secret
  stripping + drift coverage

### Modified
- `lib/screens/add_site.dart` — URL field suffix icon is the QR scanner;
  `_addByQr` pops `{qrSettings: <decoded>}` for `_addSite` to consume
- `lib/main.dart` — `_addSite` branches on `qrSettings`; the QR path
  uses `WebViewModel.fromJson(SiteSettingsQrCodec.hydrateForFromJson(...), stateSetter)`
- `lib/screens/settings.dart` — "Share QR" button wired to
  `showSiteSettingsQrShareDialog`, hidden for `file://` sites

---

## Manual Test Procedure

### Test: Round-trip a site between two devices (or two installs)
1. On device A, open per-site settings for an HTTPS site with a
   non-trivial config (e.g., proxy address set, language overridden,
   geo spoofing on, content blocker on).
2. Tap "Share QR".
3. On device B, open Add Site, tap the QR icon in the URL field, scan
   (or paste the URL via the fallback dialog).
4. **Expected**: A new site appears with the same proxy address,
   language, geo, content blocker setting. The proxy password is empty
   (the user must re-enter it). `siteId` is fresh. Cookies and user
   scripts are empty.

### Test: Hostile-key smuggle is dropped
1. Generate a payload outside the app whose JSON includes
   `"cookies": [...]` alongside `"initUrl"`.
2. Paste it into the Add Site QR fallback dialog.
3. **Expected**: The site is created from the legitimate keys; no
   cookie shows up under per-site settings → cookies.

### Test: Forward-incompatible version is rejected
1. Construct a URL `webspace://qr/site/v999/<any>`.
2. Paste it.
3. **Expected**: Inline error "Not a valid WebSpace site-settings QR.";
   dialog stays open.

### Test: Share QR hidden on file-import sites
1. Add a site via "Import file" (any local HTML).
2. Open per-site settings for the imported site.
3. **Expected**: No "Share QR" button is shown.

### Test: Share dialog dismisses after Copy / Share
1. Open Share QR for any HTTPS site.
2. Tap "Copy".
3. **Expected**: Dialog closes; snackbar "Copied to clipboard" appears.
4. Reopen Share QR, tap "Share".
5. **Expected**: OS share sheet appears; dialog closes underneath.
