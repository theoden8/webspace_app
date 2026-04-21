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
