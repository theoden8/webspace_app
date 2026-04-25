# Per-Site Location & Timezone Spoofing Specification

## Purpose

Allow users to return fake geolocation coordinates and a chosen IANA timezone to each site independently, and to prevent the WebRTC real-IP leak that bypasses HTTP(S)/SOCKS proxies.

## Status

- **Date**: 2026-04-21
- **Status**: Implemented

---

## Problem Statement

A privacy-focused browser should let users control what a site learns about their physical location. Three signals leak it today:

1. `navigator.geolocation.getCurrentPosition` / `watchPosition` — exposes real GPS / IP-derived coordinates.
2. `Intl.DateTimeFormat().resolvedOptions().timeZone`, `Date.prototype.getTimezoneOffset`, `Date.prototype.toString` — reveal the device's timezone, which cross-checks against any coordinate spoof.
3. WebRTC — `RTCPeerConnection` + STUN exposes the device's public IP even through an HTTP(S) or SOCKS5 proxy, because Android WebView's proxy API only tunnels TCP and Chromium's WebRTC UDP stack does not honor the proxy.

A single site-level toggle set is therefore required: spoof coordinates, override timezone, and lock down WebRTC.

---

## Requirements

### Requirement: LOC-001 - Per-site location mode

The system SHALL expose a per-site `locationMode` with two values: `off` (default) and `spoof`. When `spoof`, user-supplied latitude/longitude/accuracy replace the real geolocation.

#### Scenario: Off mode passes through

**Given** site "Acme" has `locationMode = off`
**When** the site calls `navigator.geolocation.getCurrentPosition(cb)`
**Then** the webview returns the platform's real geolocation (or prompts for permission)

#### Scenario: Spoof mode returns fake coords

**Given** site "Acme" has `locationMode = spoof`, `spoofLatitude = 35.6762`, `spoofLongitude = 139.6503`, `spoofAccuracy = 50`
**When** the site calls `navigator.geolocation.getCurrentPosition(cb)`
**Then** `cb` is invoked (after ~150–400ms) with a `GeolocationPosition` whose `coords.latitude ≈ 35.6762`, `coords.longitude ≈ 139.6503`, `coords.accuracy = 50`
**And** `position instanceof GeolocationPosition` is true

---

### Requirement: LOC-002 - Spoof hardening

The spoof SHALL resist trivial detection by:
- overriding `Geolocation.prototype.getCurrentPosition/watchPosition/clearWatch` (not just the instance),
- patching `Function.prototype.toString` via a `WeakMap` keyed by overridden functions so stringifying them returns `"function <name>() { [native code] }"`,
- constructing the returned `GeolocationPosition` and `GeolocationCoordinates` with the real class prototypes,
- returning `'granted'` from `navigator.permissions.query({name:'geolocation'})` so the reported permission state matches the resolved call,
- jittering coordinates by up to ~2 meters per call so `watchPosition` does not return byte-identical frames,
- introducing a 150–400ms latency so `getCurrentPosition` does not resolve synchronously-fast.

#### Scenario: Prototype method is patched

**Given** `locationMode = spoof`
**When** a site calls `Geolocation.prototype.getCurrentPosition.call(navigator.geolocation, cb)`
**Then** `cb` receives the spoofed coordinates (the prototype reference is not the unpatched native)

#### Scenario: toString reports native

**Given** `locationMode = spoof`
**When** a site evaluates `navigator.geolocation.getCurrentPosition.toString()`
**Then** the result is `"function getCurrentPosition() { [native code] }"`
**And** `Function.prototype.toString.toString()` likewise returns `"function toString() { [native code] }"`

---

### Requirement: LOC-003 - Timezone override

The system SHALL expose a per-site `spoofTimezone` (IANA name, nullable). When set, it SHALL override:
- `Intl.DateTimeFormat(locales, options)` — when `options.timeZone` is absent, the configured zone is injected so `resolvedOptions().timeZone` reports it,
- `Date.prototype.getTimezoneOffset` — returns the offset in the configured zone at the given Date instant (DST-correct via Intl),
- `Date.prototype.toString` — returns a well-formed browser-style string with the spoofed GMT offset and long timezone name.

#### Scenario: Intl reports spoofed zone

**Given** `spoofTimezone = 'Asia/Tokyo'`
**When** a site reads `new Intl.DateTimeFormat().resolvedOptions().timeZone`
**Then** the value is `'Asia/Tokyo'`

#### Scenario: getTimezoneOffset returns spoofed offset

**Given** `spoofTimezone = 'Asia/Tokyo'`
**When** a site calls `new Date().getTimezoneOffset()` at a moment when JST is UTC+9
**Then** the result is `-540`

#### Scenario: Known detection gap

**Given** `spoofTimezone = 'Asia/Tokyo'` and device real zone is `UTC`
**When** a site calls `new Date().getHours()` and compares to `Intl.DateTimeFormat('en', { hour: 'numeric', timeZone: 'Asia/Tokyo' }).format(new Date())`
**Then** the values disagree (real local vs spoofed). This is a known gap — the implementation deliberately does not override `Date` getters to keep the shim small; cross-referencing callers can detect the spoof.

**Rationale:** covering `getHours`/`getMinutes`/`getDate`/... requires shifting each call into the target zone, which is invasive and has DST-boundary edge cases. Most fingerprint libraries use `Intl` or `getTimezoneOffset`.

---

### Requirement: LOC-004 - WebRTC policy

The system SHALL expose a per-site `webRtcPolicy` with three values: `defaultPolicy` (no change), `relayOnly`, and `disabled`.

#### Scenario: Relay-only strips local candidates

**Given** `webRtcPolicy = relayOnly`
**When** a site creates a new `RTCPeerConnection(config)` and calls `setLocalDescription(offer)`
**Then** the effective config has `iceTransportPolicy = 'relay'`
**And** the SDP passed to `setLocalDescription` has all non-`typ relay` candidate lines stripped

#### Scenario: Disabled throws

**Given** `webRtcPolicy = disabled`
**When** a site evaluates `new RTCPeerConnection()`
**Then** the constructor throws `Error('WebRTC disabled')`

#### Scenario: Default policy is untouched

**Given** `webRtcPolicy = defaultPolicy`
**Then** `RTCPeerConnection` behaves exactly as the platform default

---

### Requirement: LOC-006 - Map picker with explicit opt-in

The per-site location settings SHALL provide a "Pick on map" button that opens a full-screen picker. The picker SHALL NOT make any network requests (map tile fetches) until the user explicitly taps a "Load map" button on the picker's placeholder state. Manual coordinate entry SHALL remain available without ever loading the map.

The tile URL used by the picker SHALL come from a global app pref (`osmTileUrl`, default `https://tile.openstreetmap.org/{z}/{x}/{y}.png`). The pref SHALL be editable from the app-level settings and SHALL round-trip through settings backup/restore via the existing registry in `lib/settings/app_prefs.dart`.

#### Scenario: Opening the picker makes no requests

**Given** the user has tapped "Pick on map" on the per-site location settings
**When** the picker opens
**Then** no tile requests have been made
**And** the placeholder view is shown with the configured tile host name
**And** latitude, longitude, and accuracy inputs are already editable

#### Scenario: User enters coordinates without loading the map

**Given** the picker is showing the placeholder
**When** the user types coordinates into the inputs and taps "Done"
**Then** still no tile requests have been made
**And** the picker returns the typed coordinates to the caller

#### Scenario: User loads the map

**Given** the picker is showing the placeholder
**When** the user taps "Load map"
**Then** the map is mounted
**And** tile requests begin to the URL configured in `osmTileUrl`
**And** tapping anywhere on the map updates the coordinate inputs and moves the pin

#### Scenario: Tile URL is swappable

**Given** the user has opened the app settings and changed "Tile URL" to a self-hosted tile server
**When** the user later opens the location picker and taps "Load map"
**Then** tile requests go to the configured server, not to openstreetmap.org

---

### Requirement: LOC-008 - Use current location button

The location picker SHALL expose a "Use current location" button on platforms where a native location service is wired in (Android, iOS). Tapping it SHALL request a single GPS fix from the device's native location service and populate the latitude, longitude, and accuracy inputs with the result. The implementation SHALL:

- Use Android's `android.location.LocationManager` (GPS + NETWORK providers) and iOS's `CLLocationManager`. No Google Play Services dependency, so the F-Droid flavor remains GMS-free.
- Request the runtime permission only when the user taps the button (not at app launch). On Android, request `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION`; on iOS, request `When-In-Use` authorization with `NSLocationWhenInUseUsageDescription`.
- Make NO network requests as part of fetching the fix. The button must work even when the map is not loaded (i.e. the privacy default in LOC-006 is preserved).
- Acquire a single fix, not a continuous stream. The native side stops listening as soon as the first fix arrives or the timeout expires.
- Surface failure modes distinctly: permission denied, permission denied forever (offer Settings hint), location services disabled, timeout, unsupported platform.
- Hide the button entirely on platforms where it is not supported (e.g. macOS, Linux), so it never appears as a dead control.

This is a manual user action that fills inputs the user can still edit. It does not change the per-site spoof semantics — the chosen coordinates remain whatever the user accepts via "Done", whether typed, picked on the map, or imported from the device GPS.

#### Scenario: Permission granted on first tap

**Given** the picker is open and the user has never granted location permission to the app
**When** the user taps "Use current location"
**Then** the system permission prompt appears
**And** if the user grants permission, the latitude, longitude, and accuracy inputs are populated with the device's current fix within ~30 seconds
**And** no map tile requests are made unless the user separately taps "Load map"

#### Scenario: Permission denied

**Given** the picker is open
**When** the user taps "Use current location" and denies the permission prompt
**Then** the inputs are unchanged
**And** a message explains that location permission was not granted

#### Scenario: Permission permanently denied

**Given** the user previously denied the permission with "don't ask again" (Android) or fully denied it in Settings (iOS)
**When** the user taps "Use current location"
**Then** no permission prompt appears
**And** a message explains that the permission must be re-enabled in system Settings

#### Scenario: Location services off

**Given** location services are disabled at the OS level
**When** the user taps "Use current location"
**Then** a message indicates that location services are disabled

#### Scenario: Timeout outdoors

**Given** the user has granted permission but no fix arrives within the timeout
**When** the timeout elapses
**Then** the native side stops listening for updates
**And** the picker shows a timeout message

#### Scenario: Button hidden on unsupported platforms

**Given** the picker is opened on a platform without a wired native location plugin (e.g. macOS, Linux)
**Then** the "Use current location" button is not shown

#### Scenario: No GMS dependency on Android

**Given** the F-Droid flavor APK is installed on a device without Google Play Services
**When** the user taps "Use current location"
**Then** the request still succeeds (or fails with a non-GMS status), because the implementation uses `LocationManager`, not `FusedLocationProviderClient`

---

### Requirement: LOC-007 - Settings apply to nested webviews

Every per-site field on `WebViewModel` that controls privacy behavior (`locationMode`, `spoofLatitude`, `spoofLongitude`, `spoofAccuracy`, `spoofTimezone`, `webRtcPolicy`) SHALL propagate to every `InAppWebViewScreen` spawned by cross-domain navigation from the parent site via `launchUrl` in `lib/main.dart`. The JS shim SHALL be injected into cross-origin iframes as well as the top frame by setting `forMainFrameOnly: false` on the `inapp.UserScript`.

Otherwise a site could defeat the spoof by linking to a detection page (e.g. browserleaks.com) — which opens in a nested browser — or embedding it in an iframe.

#### Scenario: Nested browser inherits the spoof

**Given** site "Acme" has `locationMode = spoof`, `spoofLatitude = 35.6762`, `spoofLongitude = 139.6503`, and `webRtcPolicy = disabled`
**When** the user follows a cross-domain link from Acme that opens a nested `InAppWebViewScreen` at browserleaks.com/webrtc
**Then** the nested webview reports the spoofed coordinates
**And** `RTCPeerConnection` is neutered in the nested webview too

#### Scenario: Iframe sees the spoof

**Given** a page embeds `https://browserleaks.com/webrtc` inside a cross-origin iframe
**When** the iframe runs its detection script
**Then** `navigator.geolocation` returns the spoofed coordinates
**And** `RTCPeerConnection` is either neutered or relay-only per the parent site's policy

---

### Requirement: LOC-005 - Persistence and backup

All six fields (`locationMode`, `spoofLatitude`, `spoofLongitude`, `spoofAccuracy`, `spoofTimezone`, `webRtcPolicy`) SHALL round-trip through `WebViewModel.toJson` / `fromJson` with sensible defaults when absent. They ride along in the `sites` array of settings backups automatically.

#### Scenario: Round-trip through JSON

**Given** a `WebViewModel` with `locationMode = spoof`, `spoofLatitude = 35.6762`, `spoofLongitude = 139.6503`, `spoofAccuracy = 25`, `spoofTimezone = 'Asia/Tokyo'`, `webRtcPolicy = relayOnly`
**When** the model is serialized via `toJson` and re-hydrated via `fromJson`
**Then** all six fields equal their original values

#### Scenario: Defaults when absent from JSON

**Given** a JSON blob from an older backup that has none of the six fields
**When** the model is hydrated via `fromJson`
**Then** `locationMode = off`, coordinates are `null`, `spoofAccuracy = 50`, `spoofTimezone = null`, and `webRtcPolicy = defaultPolicy`

---

## Implementation Notes

- Shim source: [lib/services/location_spoof_service.dart](../../lib/services/location_spoof_service.dart)
- Shim injection: [lib/services/webview.dart](../../lib/services/webview.dart) `createWebView`, added to `initialUserScripts` at `DOCUMENT_START` — **before** any other content script, content-blocker early CSS, or user-scripts shim, so overrides are in place before any site code runs.
- Model: [lib/web_view_model.dart](../../lib/web_view_model.dart)
- UI: [lib/screens/settings.dart](../../lib/screens/settings.dart) — "Location & timezone" section with mode dropdown, lat/long/accuracy inputs, timezone dropdown, WebRTC policy dropdown.
- Enum and timezone list: [lib/settings/location.dart](../../lib/settings/location.dart)
- Tests: [test/location_spoof_test.dart](../../test/location_spoof_test.dart), [test/web_view_model_test.dart](../../test/web_view_model_test.dart)

## Threat Model

The shim targets **passive detection** — sites that read Geolocation/Intl/WebRTC once and trust the result. It does NOT defend against:

- **IP-based geolocation**: a site's server can reverse-resolve your IP. Pair with a per-site proxy in the spoofed country.
- **Coordinated cross-checks**: a site that compares `getHours()` vs `Intl.DateTimeFormat` results in the target zone will notice the disagreement (see LOC-003 scenario).
- **Sensor-based location**: DeviceOrientation / magnetometer can give coarse location if granted; the shim does not intercept them.

For higher-confidence spoofing, enable all three: location spoof + matching timezone + WebRTC `relayOnly` or `disabled` + a proxy in the same country.
