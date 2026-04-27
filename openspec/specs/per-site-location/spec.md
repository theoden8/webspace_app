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

The system SHALL expose a per-site `locationMode` with three values:

- `off` (default): the JS shim does not touch `navigator.geolocation`. The webview's platform default applies.
- `spoof`: the shim replaces `navigator.geolocation` with a static-coordinates path that returns the user-supplied `spoofLatitude` / `spoofLongitude` / `spoofAccuracy` (with sub-meter jitter so `watchPosition` doesn't return byte-identical frames).
- `live`: the shim replaces `navigator.geolocation` with a callback path that, on every `getCurrentPosition` / `watchPosition` tick, asks the Dart side for a fresh fix from the platform's native location service (Android `LocationManager`, iOS `CLLocationManager`) and returns those real coordinates. `watchPosition` polls every 5 s.

In all three modes, `spoofTimezone` and `webRtcPolicy` apply independently — `live` does NOT bypass the timezone override or WebRTC policy. The on-disk values are `off` / `spoof` / `live`; existing settings backups round-trip without migration (older backups without a value default to `off`).

The UI SHALL NOT expose the mode as a separate dropdown. Instead, the per-site settings screen SHALL render a state-aware geolocation row with three states:

- **Off** (no custom coords, live disabled): subtitle "No custom location set" with two buttons — "Pick" (opens the picker → flips to spoof) and "Live" (flips to live).
- **Spoof** (custom coords): subtitle shows the coordinates and accuracy, with an edit-icon button (re-opens the picker) and a clear-icon button (flips to off).
- **Live** (live tracking): subtitle "Live: tracks device GPS via the platform location service", with a clear button that flips back to off.

`locationMode` is derived at save time:
- if the user is in the live state → `live`,
- else if both `spoofLatitude` and `spoofLongitude` are non-null → `spoof`,
- else → `off`.

The user-facing concept of "mode" is removed — the user thinks in terms of "I have a custom location", "I'm tracking my real one", or "I don't have anything set".

#### Scenario: No location set shows Pick affordance

**Given** site "Acme" has `locationMode = off` and no `spoofLatitude` / `spoofLongitude`
**When** the user opens per-site settings for Acme
**Then** the Geolocation row shows the subtitle "No custom location set"
**And** a single "Pick location" button is visible
**And** no latitude/longitude/accuracy fields are shown

#### Scenario: Picking a location flips mode to spoof

**Given** the user has tapped "Pick location" and chosen 35.6762, 139.6503 with accuracy 50 in the picker
**When** the picker returns and the user saves the per-site settings
**Then** the persisted state is `locationMode = spoof`, `spoofLatitude = 35.6762`, `spoofLongitude = 139.6503`, `spoofAccuracy = 50`
**And** subsequent `navigator.geolocation.getCurrentPosition` calls from Acme return those coordinates

#### Scenario: Clearing a location flips mode to off

**Given** site "Acme" has `locationMode = spoof`, `spoofLatitude = 35.6762`, `spoofLongitude = 139.6503`
**When** the user opens per-site settings, taps the clear (✕) icon next to the coordinates, and saves
**Then** the persisted state is `locationMode = off` and the latitude/longitude are null
**And** subsequent `navigator.geolocation.getCurrentPosition` calls from Acme return whatever the platform's webview default does (no shim)

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

### Requirement: LOC-009 - Live device location passthrough

When `locationMode = live`, the JS shim SHALL forward `navigator.geolocation.getCurrentPosition` and `navigator.geolocation.watchPosition` calls to the platform's native location service via a `flutter_inappwebview` JavaScript handler named `getRealLocation`. Each call returns a fresh fix; coordinates change as the device moves. The same shim hardening as `spoof` mode applies (prototype overrides, toString native reporting, Permissions API → granted).

The shim variable controlling the static-coordinates path SHALL be named `STATIC_LOC` (not `SPOOF_LOC`) for clarity, since both `spoof` and `live` are technically "spoofs" of `navigator.geolocation` — `STATIC_LOC` specifically gates the path that returns hardcoded coords.

The Dart-side handler for `getRealLocation` SHALL be registered in `webview.dart`'s `onWebViewCreated` only when `config.locationMode == LocationMode.live`. The handler delegates to `CurrentLocationService.getCurrentLocation()` (Android `LocationManager` / iOS `CLLocationManager`, no Google Play Services). The platform permission prompt fires the first time the page actually calls `getCurrentPosition` — not at app launch, not at site activation.

`watchPosition` SHALL poll every 5 s in live mode and stop when the page calls `clearWatch`. `options.maximumAge` and similar are ignored — the cadence is fixed by the shim, not exposed to pages.

#### Scenario: getCurrentPosition returns a real fix

**Given** site "Acme" has `locationMode = live`
**When** the site calls `navigator.geolocation.getCurrentPosition(cb)`
**Then** the platform permission prompt appears (first call only)
**And** if the user grants permission, `cb` is invoked with the device's current coordinates from the native location service
**And** the Position object has `coords.latitude`/`coords.longitude` matching the device GPS within accuracy

#### Scenario: watchPosition tracks movement

**Given** site "Acme" has `locationMode = live` and the user has granted permission
**When** the site calls `navigator.geolocation.watchPosition(cb)` and the device moves between fixes
**Then** `cb` is invoked at least every 5 s with the latest fix
**And** `cb` continues firing until the site calls `clearWatch(id)`

#### Scenario: Permission denied surfaces a GeolocationPositionError

**Given** site "Acme" has `locationMode = live`
**When** the site calls `getCurrentPosition(success, error)` and the user denies the permission prompt
**Then** the `error` callback is invoked with a `GeolocationPositionError`-shaped object whose `code` is `1` (PERMISSION_DENIED)

#### Scenario: Timezone and WebRTC apply independently

**Given** site "Acme" has `locationMode = live`, `spoofTimezone = 'Asia/Tokyo'`, `webRtcPolicy = disabled`
**When** the site reads `Intl.DateTimeFormat().resolvedOptions().timeZone` and constructs a new `RTCPeerConnection`
**Then** `Intl` reports `'Asia/Tokyo'` (the timezone override is unaffected by live mode)
**And** `RTCPeerConnection` is neutered per the policy

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

#### Scenario: System default entry shows what it entails

**Given** the per-site settings timezone dropdown is open on a device whose timezone is `Europe/Helsinki` and the wall clock reads `14:32`
**When** the user inspects the "System default" entry (the `null` option)
**Then** its label SHALL include the device's timezone name (or abbreviation), the UTC offset, and the current local time, e.g. `"System default (EEST, UTC+03:00, 14:32)"`
**And** all other timezone entries SHALL be displayed verbatim from `commonTimezones`

This is a UI affordance only — when `spoofTimezone` is `null` the JS shim is not active for timezone, so the device's real timezone is used. The label exists so the user can see what "default" actually means before deciding whether to override.

---

### Requirement: LOC-010 - Timezone from picked location

The per-site model SHALL expose a boolean field `spoofTimezoneFromLocation`. When true AND coordinates are set AND a polygon dataset is loaded, the effective spoof timezone is the IANA zone whose polygon contains `(spoofLatitude, spoofLongitude)`. `spoofTimezone` is ignored in that case (the two fields are mutually exclusive in the UI).

If the polygon dataset is absent, or the coordinates fall in a region not covered by the dataset (e.g. open ocean in the no-oceans variant), the lookup SHALL fall through to no-timezone-spoof (system default) rather than failing the whole shim. The lookup happens once at shim build time in `webview.dart`, not on every JS call, so a slow polygon test does not affect page perf after the initial page load.

The polygon dataset SHALL be downloadable on demand via App Settings → Location picker → "Timezone polygons" → Download. Default source is the `evansiroky/timezone-boundary-builder` GitHub release (zipped GeoJSON, ~7–15 MB compressed). The download URL is user-configurable so users can swap in a smaller community dataset, a self-hosted mirror, or a pre-extracted GeoJSON file. The dataset is not bundled with the app — it is opt-in. The state (loaded zone count, last-updated timestamp, configured URL) round-trips across app launches in app private storage.

The per-site Timezone dropdown SHALL include a "From picked location" entry. The entry's label SHALL preview what the lookup would resolve to right now (the IANA zone for the current coords, or a hint indicating which prerequisite is missing — "Download polygon dataset in App Settings" / "Pick a location first").

#### Scenario: Dataset not downloaded

**Given** the user has not yet downloaded the polygon dataset
**When** the user opens per-site settings and inspects the Timezone dropdown
**Then** the "From picked location" entry SHALL be present but its label SHALL include "Download polygon dataset in App Settings"

#### Scenario: Dataset downloaded, no coords picked

**Given** the user has downloaded the dataset but the site has no `spoofLatitude` / `spoofLongitude`
**When** the user opens the dropdown
**Then** the "From picked location" entry SHALL include "Pick a location first"

#### Scenario: Dataset downloaded and coords set

**Given** the user has downloaded the dataset and picked coordinates inside a covered zone (e.g. 35.6762, 139.6503)
**When** the user opens the dropdown
**Then** the "From picked location" entry SHALL include the resolved zone in parentheses (e.g. "From picked location (Asia/Tokyo)")
**And** selecting it SHALL set `spoofTimezoneFromLocation = true` and `spoofTimezone = null`

#### Scenario: Lookup miss falls through

**Given** `spoofTimezoneFromLocation = true` and the picked coords fall outside every polygon in the loaded dataset
**When** a webview is built for the site
**Then** the JS shim SHALL be built with no timezone spoof (system default applies)
**And** no error is raised — the rest of the shim (geolocation, WebRTC) builds normally

#### Scenario: Dataset is opt-in and clearable

**Given** the dataset has been downloaded
**When** the user taps the "Clear" icon next to the dataset row in App Settings
**Then** the cache file is deleted, in-memory state is cleared, and `isReady` returns false
**And** any per-site setting with `spoofTimezoneFromLocation = true` falls through to system default

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

#### Scenario: OSM Tile Usage Policy and Attribution Guidelines compliance

When the picker is configured to use the default `tile.openstreetmap.org` URL it SHALL meet the OSM Tile Usage Policy (https://operations.osmfoundation.org/policies/tiles/) and the OSMF Attribution Guidelines (adopted 2021-06-25). Specifically:

**Tile requests:**

**Given** the picker has loaded the map with the default `osmTileUrl`
**Then** every tile HTTP request SHALL carry a `User-Agent` of the form `Webspace/<version> (+https://github.com/theoden8/webspace_app)` (NOT the flutter_map library default `flutter_map (...)`)
**And** the request SHALL NOT include `Cache-Control: no-cache` or `Pragma: no-cache`
**And** the request SHALL go to the canonical `https://tile.openstreetmap.org/{z}/{x}/{y}.png` URL (no other subdomains, no HTTP)
**And** the picker SHALL NOT pre-fetch, bulk-download, or offer "save area for offline" features
**And** the picker SHALL NOT mount the map (issue any tile request) until the user taps "Load map" — the LOC-006 opt-in is preserved

**Attribution (Attribution Guidelines):**

**And** the attribution overlay SHALL be visible on every map view, in a corner, without requiring the user to interact with the map
**And** the text SHALL include the word `OpenStreetMap` styled visibly as a hyperlink (underlined and link-coloured), with the link target https://www.openstreetmap.org/copyright (acceptable historical form: `© OpenStreetMap contributors`)
**And** the link SHALL be the word `OpenStreetMap` itself, not just the surrounding `©` glyph or the entire string (per the Attribution Guidelines, "by making the text 'OpenStreetMap' a link to openstreetmap.org/copyright")
**And** the font size SHALL be at least 12 points and contrast with its background to meet WCAG legibility expectations (the guidelines reference WCAG)
**And** a "Report a map issue" link to https://www.openstreetmap.org/fixthemap SHALL be visible adjacent to the attribution

**License documentation:**

**And** the in-app License screen SHALL include an entry titled "OpenStreetMap (map data and tiles)" explaining the ODbL (data) / CC BY-SA 2.0 (cartography) split, commercial-use compatibility, and the policy commitments above

OpenStreetMap data is © OpenStreetMap contributors and licensed under ODbL; the cartography is CC BY-SA 2.0. These are compatible with commercial use as long as attribution is preserved. Tile-server access from `tile.openstreetmap.org` is best-effort and may be withdrawn by the OSMF at any time per their policy; users who require guaranteed availability or offline maps SHALL configure a self-hosted or commercial tile provider via the `osmTileUrl` app pref.

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

Every per-site field on `WebViewModel` that controls privacy behavior (`locationMode`, `spoofLatitude`, `spoofLongitude`, `spoofAccuracy`, `spoofTimezone`, `spoofTimezoneFromLocation`, `webRtcPolicy`) SHALL propagate to every `InAppWebViewScreen` spawned by cross-domain navigation from the parent site via `launchUrl` in `lib/main.dart`. The JS shim SHALL be injected into cross-origin iframes as well as the top frame by setting `forMainFrameOnly: false` on the `inapp.UserScript`.

When the parent's mode is `live`, nested webviews SHALL inherit the live behavior — including the `getRealLocation` JS handler registration in `webview.dart`'s `onWebViewCreated` — so that a nested browser opened from the parent site continues to read fresh device coords through the shim, not platform-default geolocation.

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
