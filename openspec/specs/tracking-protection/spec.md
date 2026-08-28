# Enhanced Tracking Protection (umbrella)

## Status
**Implemented**

## Purpose

Bundle the per-site tracker-blocking surfaces (`clearUrlEnabled`,
`dnsBlockEnabled`, `contentBlockEnabled`, `localCdnEnabled`) and an
anti-fingerprinting JS shim under one umbrella per-site toggle, modelled
on Firefox's "Enhanced Tracking Protection". When the umbrella is on,
the site is forced into the strongest-supported posture without users
having to enable each axis separately; when it's off, the four sub-
toggles fall back to their independent values.

## Problem Statement

Two distinct problem classes that an end user shouldn't have to think
about separately:

1. **Tracker network requests.** ClearURLs strips known tracking params,
   the DNS blocklist drops requests to known-tracker domains, the
   content blocker hides ad/tracker subresources via filter lists, and
   LocalCDN serves popular third-party CDN libraries from an on-device
   cache so the CDN provider can't observe browsing activity. Each has
   its own toggle, and a user who wants "block trackers for this site"
   today has to know to flip four switches.
2. **Browser fingerprinting.** Tracker scripts that can't load network
   beacons can still re-identify a user across sessions via Canvas
   pixel hashes, WebGL vendor/renderer strings, audio synthesis output,
   font enumeration, screen dimensions, window/viewport dimensions,
   hardware concurrency, plugin lists, battery state, voice list,
   high-resolution timers, and element bounding boxes. None of these
   were addressed.

The umbrella addresses both: one switch, both behaviours.

## Solution

Add a per-site `trackingProtectionEnabled` boolean (default true) to
`WebViewModel`. When true:

* The four pre-existing toggles (`clearUrlEnabled`, `dnsBlockEnabled`,
  `contentBlockEnabled`, `localCdnEnabled`) behave as ON regardless of
  their stored value — `WebViewModel.getWebView` and
  `InAppWebViewScreen` compute `effective = stored ||
  trackingProtectionEnabled` and pass that to `WebViewConfig`.
* When a static spoof location is set, the timezone is forced to
  "from picked location" so `Date` / `Intl` match the spoofed geo.
  The geolocation mode itself (`off` / `spoof` / `live`) is NOT
  touched by the umbrella — legitimate uses such as maps and
  ride-share need live GPS even under tracker protection, and the
  user is in control of which mode applies per site.
* A JS shim
  ([lib/services/anti_fingerprinting_shim.dart](../../../lib/services/anti_fingerprinting_shim.dart))
  is injected at `DOCUMENT_START` into every frame of the site,
  patching the surfaces enumerated below seeded by the per-site
  `siteId`. Per-site stability + cross-site uniqueness is delivered by
  a Mulberry32 PRNG keyed off an FNV-1a hash of the seed.

When false, the four sub-toggles act independently as they did pre-
umbrella, the anti-fingerprinting shim is not injected, any stored
timezone is honoured, and per-site fingerprinting protection is off.

---

## Requirements

### Requirement: ETP-001 - Umbrella per-site toggle

Each site SHALL have a `trackingProtectionEnabled` setting (default
true) controlling the umbrella.

#### Scenario: Default enabled

**Given** a new site is created
**Then** `trackingProtectionEnabled` defaults to `true`

#### Scenario: Setting persists

**Given** a site has Tracking Protection disabled
**When** the app is restarted
**Then** the setting remains disabled

#### Scenario: Backward compatibility on upgrade

**Given** a site stored under a previous app version (no
`trackingProtectionEnabled` key)
**When** the model is deserialised
**Then** `trackingProtectionEnabled` is `true`

---

### Requirement: ETP-002 - Subordinate toggles forced on under umbrella

The umbrella SHALL force ClearURLs, DNS blocklist, content blocker, and LocalCDN to behave as on whenever `trackingProtectionEnabled` is true, regardless of their stored per-site values.

#### Scenario: Stored ClearURLs disabled, umbrella on

**Given** `clearUrlEnabled` is false and `trackingProtectionEnabled` is
true
**When** the webview is constructed
**Then** the `WebViewConfig` passed to `WebViewFactory.createWebView`
has `clearUrlEnabled: true`
**And** the same forcing applies to nested webviews opened by
`launchUrl`

#### Scenario: Stored LocalCDN disabled, umbrella on

**Given** `localCdnEnabled` is false and `trackingProtectionEnabled` is
true
**When** the webview is constructed
**Then** the `WebViewConfig` passed to `WebViewFactory.createWebView`
has `localCdnEnabled: true`
**And** the same forcing applies to nested webviews opened by
`launchUrl`

#### Scenario: Umbrella off restores subordinate values

**Given** `clearUrlEnabled` is false and `trackingProtectionEnabled` is
false
**When** the webview is constructed
**Then** the `WebViewConfig` has `clearUrlEnabled: false`

#### Scenario: Privacy UI reflects forcing

**Given** `trackingProtectionEnabled` is true on the site Privacy screen
(ETP-017)
**Then** the ClearURLs / DNS / Content Blocker / LocalCDN
`SwitchListTile`s show `value: true`
**And** their `onChanged: null` (visually disabled)
**And** their subtitle keeps describing the setting rather than repeating
the forcing, which the disabled switch already shows

---

### Requirement: ETP-003 - Anti-fingerprinting shim injected

The system SHALL inject the JS shim from `lib/services/anti_fingerprinting_shim.dart` at `DOCUMENT_START` with `forMainFrameOnly: false` whenever `trackingProtectionEnabled` is true and the site has a `siteId`, so iframes are also covered.

The same shim SHALL additionally be installed into `Worker` / `SharedWorker`
global scopes per `worker-shim-propagation`, since a worker re-reading these
surfaces would otherwise bypass the shim entirely. The seeded values MUST be
identical in page and worker (WORK-002), and the window-only sections (`screen.*`,
the `matchMedia` wrapper, `plugins` / `mimeTypes` / `getBattery`) MUST NOT be
applied in worker scope (WORK-003).

#### Scenario: Shim injected on construction

**Given** a webview is constructed for a site with the umbrella on
**Then** the `userScripts` list passed to `inapp.InAppWebView` contains
a `UserScript` with `groupName: 'anti_fingerprinting'`
**And** `injectionTime: AT_DOCUMENT_START`
**And** `forMainFrameOnly: false`

#### Scenario: Shim NOT injected when umbrella off

**Given** the umbrella is off
**When** the webview is constructed
**Then** no script with `groupName: 'anti_fingerprinting'` is injected

#### Scenario: Shim NOT injected without siteId

**Given** the umbrella is on but `config.siteId` is null
**Then** the shim is not injected (no seed available)

---

### Requirement: ETP-004 - Per-site stability and cross-site uniqueness

The shim's randomized values SHALL be deterministic per `siteId` so a
site sees the same fingerprint across launches, but distinct seeds
SHALL produce distinct shim sources so two sites differ.

#### Scenario: Same seed reproduces the same shim

**Given** `buildAntiFingerprintingShim('seed-A')` returns string `S1`
**When** the same builder is invoked again with the same seed
**Then** the result equals `S1`

#### Scenario: Different seeds produce different shim text

**Given** `buildAntiFingerprintingShim('seed-A')` returns `S1`
**And** `buildAntiFingerprintingShim('seed-B')` returns `S2`
**Then** `S1 != S2`
**And** both contain the literal seed string for the FNV-1a hash

---

### Requirement: ETP-005 - Canvas 2D fingerprinting

The shim SHALL patch `CanvasRenderingContext2D.prototype.getImageData`,
`HTMLCanvasElement.prototype.toDataURL`, and
`HTMLCanvasElement.prototype.toBlob` so the underlying pixel buffer is
perturbed by a seeded noise pass before reads.

#### Scenario: getImageData call delegates to original and returns ImageData

**Given** the shim is loaded
**When** `ctx.getImageData(0, 0, w, h)` is called
**Then** the original `getImageData` is invoked once
**And** an ImageData with `data` of length `w*h*4` is returned

#### Scenario: toDataURL nudges a pixel before reading

**Given** the shim is loaded
**When** `canvas.toDataURL()` is called
**Then** a single seeded `fillRect(x, y, 1, 1)` is issued first
**And** the original `toDataURL` is then invoked

---

### Requirement: ETP-006 - WebGL fingerprinting

The shim SHALL patch `WebGLRenderingContext.prototype` and
`WebGL2RenderingContext.prototype` so:

* `getParameter(7936 | 7937 | 37445 | 37446)` returns the constant
  strings `'WebSpace'` / `'WebSpace WebGL'` (GL_VENDOR / GL_RENDERER /
  UNMASKED_VENDOR_WEBGL / UNMASKED_RENDERER_WEBGL).
* `getSupportedExtensions()` returns a constant minimal list:
  `['OES_texture_float', 'OES_element_index_uint', 'WEBGL_depth_texture']`.
* `readPixels(...)` invokes the original then applies seeded noise to
  the destination pixel array.

#### Scenario: getParameter masks vendor / renderer

**Given** the shim is loaded
**Then** `gl.getParameter(37445)` returns `'WebSpace'`
**And** `gl.getParameter(37446)` returns `'WebSpace WebGL'`
**And** `gl.getParameter(7936)` returns `'WebSpace'`
**And** `gl.getParameter(7937)` returns `'WebSpace WebGL'`

#### Scenario: getSupportedExtensions masks vendor extensions

**Given** the underlying `getSupportedExtensions` returns
`['OES_texture_float', 'WEBGL_VENDOR_LEAK_X']`
**When** the wrapped method is called
**Then** the returned list is exactly the constant minimal list
**And** `WEBGL_VENDOR_LEAK_X` is not present

#### Scenario: getParameter falls through for non-vendor params

**Given** `gl.getParameter(1)` is called (any pname not in
{7936, 7937, 37445, 37446})
**Then** the original `getParameter(1)` is invoked

---

### Requirement: ETP-007 - Audio fingerprinting

The shim SHALL patch `AudioBuffer.prototype` and `AnalyserNode.prototype`
so audio samples returned to JS are perturbed by inaudibly-small seeded
noise (waveform 1e-7 magnitude, dB-scale frequency 1e-4 magnitude).

#### Scenario: getChannelData applies noise

**Given** an `AudioBuffer` whose underlying channel data is uniformly
0.5
**When** `getChannelData(0)` is called via the wrapped method
**Then** the returned `Float32Array` contains values ≈0.5 but NOT
exactly 0.5
**And** the maximum deviation is below 1e-6

#### Scenario: getFloatFrequencyData applies dB noise

**Given** an `AnalyserNode` whose underlying frequency data is
uniformly -100 dB
**When** `getFloatFrequencyData(arr)` is called
**Then** `arr` contains values ≈-100 but NOT exactly -100
**And** the maximum deviation is below 1e-3

---

### Requirement: ETP-008 - Text-metrics jitter

The shim SHALL patch `CanvasRenderingContext2D.prototype.measureText`
and `OffscreenCanvasRenderingContext2D.prototype.measureText` so every
numeric `TextMetrics` field is multiplied by a seeded `1 ± 0.0001`
factor (±0.01% multiplicative jitter). The wrapper SHALL preserve the
shape (every original key copied; non-numeric values pass through).

#### Scenario: measureText returns jittered width

**Given** the underlying `measureText('hello')` returns `width: 42`
**When** the wrapped method is called
**Then** the returned width is in the open interval (41.9958, 42.0042)
**And** is not exactly 42

#### Scenario: jitter is deterministic per (seed, text)

**Given** the same seed is used in two domain reloads
**Then** `measureText('hello').width` is identical across reloads

#### Scenario: jitter differs per seed

**Given** seeds `A` and `B` are different
**Then** `measureText('hello').width` differs between the two seeds

---

### Requirement: ETP-009 - Font enumeration restriction

The shim SHALL patch `document.fonts.check` to answer `true` only for
families in a small allowlist of platform-common fonts (`serif`,
`sans-serif`, `monospace`, `cursive`, `fantasy`, `system-ui`, `arial`,
`helvetica`, `times`, `times new roman`, `courier`, `courier new`,
`verdana`, `georgia`, `tahoma`, `trebuchet ms`, `impact`). All other
families SHALL read as not-installed even if they actually are.

#### Scenario: Common font reads as installed

**Given** the shim is loaded
**When** `document.fonts.check('12px Arial')` is called
**Then** the result is `true`

#### Scenario: Uncommon font reads as not-installed

**Given** the shim is loaded
**When** `document.fonts.check('12px UnobtainableFont')` is called
**Then** the result is `false`

---

### Requirement: ETP-010 - Screen / hardware overrides

The shim SHALL define getters on `Screen.prototype` and
`Navigator.prototype` (NOT on the instance — own-property leak would
self-incriminate) so:

* `screen.width = 1920`, `screen.height = 1080`
* `screen.availWidth = 1920`, `screen.availHeight = 1040`
* `screen.colorDepth = 24`, `screen.pixelDepth = 24`
* `navigator.hardwareConcurrency` ∈ [4, 8] derived from the seed
* `navigator.deviceMemory` ∈ {4, 8} derived from the seed
* `navigator.plugins` and `navigator.mimeTypes` are empty
  PluginArray-shaped objects (with `length`, `item`, `namedItem`, and
  for plugins `refresh`).

The shim SHALL ALSO wrap `window.matchMedia` so single-feature
`(min-|max-)?device-width` / `device-height` media queries resolve against
the SAME dimensions `screen.*` reports — the pinned `SCREEN_W`/`SCREEN_H`
(1920x1080) normally, or the live `window.inner*` in letterbox mode
(ETP-020). Without this, a fingerprinter binary-searching
`(max-device-width: Npx)` recovers the real screen size and contradicts
`screen.width` (CreepJS's "CSS Media Queries" leak). Non-device queries fall
through to the real implementation, and the wrapper stringifies as
`[native code]`.

#### Scenario: screen dimensions pinned

**Given** the shim is loaded under jsdom
**Then** `window.screen.width === 1920` and `window.screen.height === 1080`

#### Scenario: device-dimension media queries agree with screen.*

**Given** the shim is loaded (non-letterbox)
**Then** `matchMedia('(max-device-width: 1920px)').matches` is `true`
**And** `matchMedia('(max-device-width: 1919px)').matches` is `false`
**And** `matchMedia('(device-height: 1080px)').matches` is `true`
**And** a non-device query such as `(min-width: 100px)` is delegated to the
real `matchMedia`

#### Scenario: Overrides do NOT leak as own-properties

**Given** the shim is loaded
**Then** `Object.getOwnPropertyNames(navigator)` does NOT contain any
of `hardwareConcurrency`, `deviceMemory`, `plugins`, `mimeTypes`,
`getBattery`
**And** `Object.getOwnPropertyNames(screen)` does NOT contain `width`,
`height`, `colorDepth`, or `pixelDepth`

---

### Requirement: ETP-020 - Letterbox window sizing

Sites with `letterboxEnabled` SHALL render the WebView in a centered box
sized to the available area snapped DOWN to a grid (Tor-style
letterboxing), with the leftover area drawn as a margin, so the real
viewport (`window.inner*`) is bucketed and many device sizes collapse onto
the same value. The grid starts at 200x100 logical pixels and is refined
per axis (halving the step) until the trimmed margin is at most
`kLetterboxMaxMarginFraction` (1/8) of that axis, so a phone-width viewport
keeps a thin margin instead of collapsing to a 200px sliver (a flat
200-grid floors 390 -> 200, trimming ~half). A maximised desktop window
still snaps to the 200x100 grid (1366 -> 1200, 768 -> 700). The sizing is
pure Flutter (`computeLetterboxTarget` +
a `LayoutBuilder`/`SizedBox` wrapper around the cached `InAppWebView`); a
layout change (rotation) re-snaps the box without rebuilding the WebView
(no page reload). Because the box is real, the shim SHALL NOT fake
`window.inner*`; instead, in letterbox mode it SHALL make `screen.width`,
`screen.height`, `screen.availWidth`, and `screen.availHeight` mirror the
live `window.inner*` so screen and window agree (rather than the fixed
1920x1080 of ETP-010). Letterboxing is gated on `trackingProtectionEnabled`
(the shim is) and propagates to nested webviews via `launchUrl`.

#### Scenario: Available area snaps down to the grid

**Given** an available area of 1366 x 768
**When** `computeLetterboxTarget` runs with the default 200x100 grid
**Then** the box is 1200 x 700
**And** two nearby phone widths (e.g. 405 and 414) collapse onto the same
400px box

#### Scenario: Margin stays a thin strip on every screen size

**Given** any available area across the phone-to-desktop range (e.g. 320,
375, 390, 414, 768, 1366, 1920 wide)
**When** `computeLetterboxTarget` runs with the default grid
**Then** the box never exceeds the available area
**And** the trimmed margin on each axis is at most 1/8 of that axis (a
390-wide phone yields a ~350px box, not 200)

#### Scenario: screen.* mirrors the letterboxed viewport

**Given** the shim is loaded with `letterbox: true`
**Then** `screen.width === window.innerWidth` and
`screen.height === window.innerHeight`
**And** changing `window.innerWidth` (a re-snap) is reflected by
`screen.width`

#### Scenario: Non-letterbox keeps the fixed screen and real window

**Given** the shim is loaded with `letterbox: false`
**Then** `screen.width === 1920` / `screen.height === 1080` (ETP-010)
**And** `window.inner*` is left at its real value

---

### Requirement: ETP-021 - User-set letterbox box size

`WebViewModel` SHALL carry per-site `letterboxEnabled` (default false,
omitted from `toJson` when false) and `spoofWindowWidth` /
`spoofWindowHeight` integers (default null, omitted when null). When
letterboxing is on and both dimensions are set and positive, the box SHALL
be exactly that size, capped to the available area so it never overflows
the screen; otherwise it snaps to the grid (ETP-020). All three fields
SHALL flow into `WebViewConfig` and propagate to nested webviews opened via
`launchUrl`.

#### Scenario: Fixed box size used when it fits

**Given** available 1920x1080 with `spoofWindowWidth: 1024`,
`spoofWindowHeight: 768`
**Then** `computeLetterboxTarget` returns 1024 x 768

#### Scenario: Fixed box capped to the available area

**Given** available 400x800 with `spoofWindowWidth: 1920`,
`spoofWindowHeight: 1080`
**Then** the box is 400 x 800

#### Scenario: Fields round-trip and omit at default

**Given** a site with `letterboxEnabled: false` and null box dimensions
**Then** `toJson` omits `letterboxEnabled`, `spoofWindowWidth`, and
`spoofWindowHeight`
**And** a site with the fields set survives a `toJson` / `fromJson`
round-trip

#### Scenario: Settings UI gates the box size on letterboxing

**Given** the per-site Settings screen
**Then** a "Letterbox window" switch is shown under Tracking Protection,
enabled only when `trackingProtectionEnabled` is on
**And** the box width/height fields are enabled only when both Tracking
Protection and Letterbox are on

---

### Requirement: ETP-022 - Fingerprint reroll on data clear

`WebViewModel` SHALL carry a per-site `fingerprintResetNonce` (default
null, omitted from `toJson` when null) that is mixed into the
anti-fingerprinting seed. `computeAntiFingerprintingSeed` SHALL fold a
non-empty nonce in as `siteId:resetNonce` (and
`siteId:resetNonce:launchNonce` for incognito), leaving the seed equal to
the bare `siteId` when the nonce is null/empty so sites stored before this
field existed keep their fingerprint until reset. Clearing a site's data
SHALL regenerate the nonce (`WebViewModel.rerollFingerprint`) so the
rebuilt webview's entire fingerprint — canvas, WebGL, audio, window size
(ETP-020/021), hardware, etc. — rerolls and the site cannot re-identify
the user across the wipe. The nonce SHALL propagate to nested webviews via
`launchUrl`.

#### Scenario: Seed unchanged when no reset has happened

**Given** a site with `fingerprintResetNonce` null
**Then** `computeAntiFingerprintingSeed` returns the bare `siteId`
(non-incognito) or `siteId:launchNonce` (incognito)

#### Scenario: Reset nonce folds into the seed

**Given** `resetNonce` is `"r1"`
**Then** the non-incognito seed is `siteId:r1`
**And** the incognito seed is `siteId:r1:launchNonce`

Clearing a site's data SHALL additionally remove the two app-side artefacts
that are keyed by `siteId` and replayed on the site's next activation, in
**both** engine modes and outside every `SiteDataClearEngine` plan branch:

- the saved `controller.saveState()` bytes
  (`WebViewStateStorage.removeState`), plus any capture still pending on the
  `NavStateCaptureDebouncer`;
- the encrypted HTML snapshot (`HtmlCacheService.deleteCache`).

Neither is reached by a container wipe or a cookie delete, and both restore
the pre-clear URL. A page that ran
`history.pushState(null, '', '/?uid=ABC')` before the clear is reloaded at
that URL afterwards and reads its own identifier back, which defeats the
reroll this requirement exists to guarantee. The delete-site and
archive-close paths already removed both; the clear path had drifted.

#### Scenario: Clearing site data rerolls the fingerprint

**Given** a site whose data is cleared
**When** `rerollFingerprint` runs
**Then** `fingerprintResetNonce` becomes a fresh non-empty value
**And** the regenerated anti-fingerprinting seed differs from the
pre-clear seed
**And** the new value round-trips through `toJson` / `fromJson`

#### Scenario: Clearing site data leaves nothing restorable

**Given** a site that pushed `/?uid=ABC` into its own history and whose
navigation state and HTML snapshot are on disk
**When** the user taps "Clear Site Data"
**Then** the pending debounced capture is cancelled
**And** `removeState(siteId)` and `deleteCache(siteId)` both run
**And** the rebuilt webview loads `initUrl`, not `/?uid=ABC`
**And** this holds whether the container engine or the legacy engine is live

---

### Requirement: ETP-011 - Battery and speech-synthesis

The shim SHALL define `navigator.getBattery()` to resolve a Promise of
fixed values (`charging: true`, `chargingTime: 0`,
`dischargingTime: Infinity`, `level: 1`) and shall override
`SpeechSynthesis.prototype.getVoices` to return an empty array.

#### Scenario: getBattery returns fixed values

**Given** the shim is loaded
**When** `await navigator.getBattery()` is awaited
**Then** the result has `charging === true`, `level === 1`,
`dischargingTime === Infinity`

#### Scenario: speechSynthesis voice list is empty

**Given** the shim is loaded
**When** `(new SpeechSynthesis()).getVoices()` is called
**Then** the result is `[]`

---

### Requirement: ETP-012 - Timing quantization

The shim SHALL patch `performance.now()` and `Date.now()` so the
returned value is quantized to 100 ms.

#### Scenario: performance.now is divisible by 100

**Given** the shim is loaded
**When** `performance.now()` is called
**Then** the returned value is divisible by 100

#### Scenario: Date.now is divisible by 100

**Given** the shim is loaded
**When** `Date.now()` is called
**Then** the returned value is divisible by 100

---

### Requirement: ETP-013 - ClientRects sub-pixel jitter

The shim SHALL patch `Element.prototype.getBoundingClientRect` and
`Range.prototype.getBoundingClientRect` so the returned rect's `x` /
`y` / `left` / `top` / `right` / `bottom` carry a seeded ±0.001 px
jitter. `width` and `height` are unchanged. The result SHALL include a
`toJSON()` method so `JSON.stringify` of the rect remains stable.

#### Scenario: bounding rect carries sub-pixel jitter

**Given** the shim is loaded and an element with raw rect
`{x:0, y:0, w:100, h:50}`
**When** `el.getBoundingClientRect()` is called
**Then** the returned `r.x` is in the open interval (-0.001, 0.001)
**And** `r.x !== 0`

#### Scenario: jitter is deterministic per (seed, element identity)

**Given** the shim is loaded
**When** `el.getBoundingClientRect()` is called twice on the same
element
**Then** both calls return the same `x` / `y`

---

### Requirement: ETP-014 - Function.prototype.toString hardening

Every wrapper installed by the shim SHALL be recorded into the
`__wsFnStubs` WeakMap (shared with `desktop_mode_shim.dart` and
`location_spoof_service.dart`) so `Function.prototype.toString.call(fn)`
returns the `[native code]` stub instead of the wrapper's source. The
patched `Function.prototype.toString` itself SHALL stringify as
`[native code]` so a fingerprinter probing toString-of-toString cannot
detect the patch.

#### Scenario: wrapped method stringifies as native

**Given** the shim is loaded
**When** `Function.prototype.toString.call(canvas.getContext)` is called
**Then** the result matches `/\[native code\]/`

#### Scenario: patched toString itself stringifies as native

**Given** the shim is loaded
**When** `Function.prototype.toString.call(Function.prototype.toString)`
is called
**Then** the result matches `/\[native code\]/`

---

### Requirement: ETP-025 - Wrapper prototypes do not leak the native constructor

Any shim that wraps a constructor and takes the native prototype object
(`Wrapped.prototype = Native.prototype`) SHALL re-point that object's own
`constructor` property at the wrapper:

```js
try {
  Object.defineProperty(Wrapped.prototype, 'constructor',
    { value: Wrapped, writable: true, configurable: true });
} catch (e) {}
```

Without it the native constructor stays reachable as
`Wrapped.prototype.constructor` and the whole wrapper is one expression away
from being bypassed — the same class of escape as an un-stubbed
`Function.prototype.toString` (ETP-014), and the same class as a realm the
shims never reach (BUG-009). The re-point also keeps `instance.constructor`
consistent with the global the page can see, which a mismatch would otherwise
expose as a tell.

The `defineProperty` SHALL be individually guarded so a non-configurable
prototype degrades to "this one wrapper is bypassable" rather than throwing out
of the shim payload, where an uncaught error silences every shim after it.

#### Scenario: The native constructor is not reachable through the wrapper

**Given** any shim-wrapped constructor `C` (`RTCPeerConnection`,
`Intl.DateTimeFormat`, `Worker`, `SharedWorker`, …)
**When** a page evaluates `C.prototype.constructor`
**Then** it is the wrapper, identical to the global `C`
**And** constructing through it applies the same per-site policy

---

### Requirement: ETP-015 - Re-entrance guard

The shim SHALL short-circuit on second injection via a window-scoped
guard `__ws_anti_fp_shim__`, because Android System WebView and
WKWebView both re-run `initialUserScripts` on every frame. Without the
guard, every wrapper would wrap its previous wrapping and amplify the
seeded noise per frame.

#### Scenario: Second injection is a no-op

**Given** the shim is loaded once
**And** `measureText('x').width === w0`
**When** the shim is loaded a second time in the same window
**Then** `measureText('x').width === w0` (unchanged)

---

### Requirement: ETP-018 - Geolocation and timezone forcing

When `trackingProtectionEnabled` is true the umbrella SHALL, if a
static spoof location is set (`spoofLatitude` and `spoofLongitude`
both non-null), force the effective timezone to "from picked location"
(`spoofTimezoneFromLocation: true`, `spoofTimezone: null`) so spoofed
`Date` / `Intl.DateTimeFormat` values match the spoofed geo. With no
spoof location set the umbrella SHALL leave the timezone untouched.
The umbrella SHALL NOT modify `locationMode`: `off` / `spoof` / `live`
flow to `WebViewConfig` verbatim because legitimate use cases (maps,
navigation, weather) need real GPS even under tracker-blocking, and
the geolocation mode is the user's per-site choice. Stored fields on
`WebViewModel` are unchanged; only the `WebViewConfig` sees the
forced timezone values, and the same forcing applies to nested
webviews via `InAppWebViewScreen.initState`.

#### Scenario: Live location is independent of the umbrella

**Given** a site with `locationMode: LocationMode.live` and
`trackingProtectionEnabled: true`
**When** the webview is constructed
**Then** the `WebViewConfig` has `locationMode: LocationMode.live`
**And** the same passthrough applies to nested webviews

#### Scenario: Static spoof coords force from-location timezone

**Given** a site with `spoofLatitude: 48.8`, `spoofLongitude: 2.3`,
`spoofTimezone: 'America/New_York'`, `spoofTimezoneFromLocation: false`,
and `trackingProtectionEnabled: true`
**When** the webview is constructed
**Then** the `WebViewConfig` has `spoofTimezone: null`
**And** `spoofTimezoneFromLocation: true`

#### Scenario: No coords leaves timezone untouched

**Given** a site with `spoofLatitude: null`, `spoofLongitude: null`,
`spoofTimezone: 'Europe/London'`, `spoofTimezoneFromLocation: false`,
and `trackingProtectionEnabled: true`
**When** the webview is constructed
**Then** the `WebViewConfig` has `spoofTimezone: 'Europe/London'`
**And** `spoofTimezoneFromLocation: false`

#### Scenario: Settings UI keeps Live selectable under the umbrella

**Given** the umbrella is on
**Then** the per-site Settings geolocation `SegmentedButton` Live
segment is rendered enabled and selectable
**And** when spoof coords are set the timezone `DropdownButtonFormField`
locks to "From picked location" with `onChanged: null` and a helper
text of "Forced to "From picked location" by Tracking Protection"
**And** when no spoof coords are set the timezone dropdown remains
editable

---

### Requirement: ETP-016 - Nested webview propagation

The system SHALL propagate `trackingProtectionEnabled` to every nested `InAppWebViewScreen` opened via `launchUrl` so a nested page sees the same umbrella posture as the parent (shim injected and subordinates forced when true; subordinates passed verbatim and shim NOT injected when false).

#### Scenario: Umbrella propagates to nested

**Given** the parent site has `trackingProtectionEnabled: true`
**When** a nested webview is opened via `launchUrl`
**Then** the constructed `InAppWebViewScreen.trackingProtectionEnabled`
is `true`
**And** the constructed `WebViewConfig.trackingProtectionEnabled` is
`true`

---

### Requirement: ETP-017 - Privacy screen

Everything that decides what a site can learn SHALL live on one per-site
Privacy screen (`SitePrivacyScreen`), reached from a single row in site
settings. The screen SHALL present, in order: Incognito mode as a
prominent card; the umbrella as a second prominent card labeled "Tracking
Protection" with subtitle "Anti-fingerprinting + force tracker blocking";
a "Trackers and ads" group holding ClearURLs, DNS Blocklist, Content
Blocker, LocalCDN (Android only) and Third-party cookies; and a
"Fingerprinting" group holding the letterbox switch.

Subordinates SHALL render `onChanged: null` while the umbrella is on,
with `value: true` for ETP-002's four and `value: false` for third-party
cookies (ETP-024). Only the third-party cookies row SHALL caption the
forcing ("Forced off by Tracking Protection"): a locked switch already
reads as locked, and repeating the reason on all five rows displaced the
one fact those subtitles carry, which is whether a blocker's data has
been downloaded. Forcing something *off* is the direction a reader does
not predict, so that row keeps its note. The LocalCDN subordinate is
gated additionally by `LocalCdnService.instance.hasCache` — its effective
value is `(stored || umbrella) && hasCache`, since it has no effect
without a populated cache.

Incognito mode leads the screen and SHALL NOT be forced by the umbrella:
a block-list turning itself on costs the user nothing, whereas incognito
discards their session on every restart. Grouping is by topic; forcing is
reserved for settings whose worst case is a missing page element or a
closed tracking channel.

HTML caching SHALL NOT appear here. It decides whether a page is redrawn
from disk on a cold start, which is a behaviour of the app rather than
something a site learns; it lives with the other behaviour switches on
the settings screen.

The anti-fingerprinting note under the letterbox group SHALL render only
while the umbrella is on, since with it off nothing is being randomised.

The screen SHALL own no persistent state. `SiteSettingsScreen` keeps the
fields, the dirty-snapshot diff and the save path (BUG-006 / EDIT-009);
the screen reads a `SitePrivacyValues` and reports whole values back
through `onChanged`.

The Privacy and Permissions rows SHALL sit at the foot of site settings
under a "Site" heading, below the leaf switches, Privacy first. They are
the two rows a reader visits deliberately; the switches above are what
they scroll past on the way to something else.

The Privacy row SHALL summarise the current posture without being opened:
"Tracking Protection on" while the umbrella is on, otherwise the names of
the enabled protections (at most two, then a "{count} more" overflow), or
"No protection enabled" when none is.

#### Scenario: Incognito leads, umbrella follows

**Given** the user opens the per-site Privacy screen
**Then** an Incognito mode switch is shown above the "Tracking
Protection" switch
**And** both are rendered above the ClearURLs / DNS Blocklist / Content
Blocker / LocalCDN / Third-party cookies switches

#### Scenario: Subordinates disabled while umbrella is on

**Given** the umbrella is on
**Then** the ClearURLs, DNS Blocklist, and Content Blocker switches show
`value: true`
**And** the LocalCDN switch shows `value: true` when
`LocalCdnService.instance.hasCache` is true (otherwise `false`, since
the cache is empty)
**And** the Third-party cookies switch shows `value: false`
**And** their `onChanged` is `null` (Material renders the switch grey)

#### Scenario: The forcing is captioned once, not five times

**Given** the umbrella is on
**Then** no "Forced on by Tracking Protection" subtitle is rendered
**And** the Third-party cookies row reads "Forced off by Tracking
Protection"
**And** the ClearURLs row keeps its own description

#### Scenario: Subordinates editable while umbrella is off

**Given** the umbrella is off
**Then** the five subordinate switches are tappable
**And** their values reflect the per-site stored booleans

#### Scenario: Incognito stays the user's own decision

**Given** the umbrella is on
**Then** the Incognito mode switch is still tappable
**And** its value reflects the per-site stored boolean

#### Scenario: Settings row summarises without opening

**Given** a site with the umbrella off and only ClearURLs enabled
**Then** the Privacy row in site settings reads "ClearURLs"
**And** with the umbrella on it reads "Tracking Protection on"
**And** with nothing enabled it reads "No protection enabled"

---

### Requirement: ETP-019 - Android native privacy settings under umbrella

The umbrella SHALL apply the fork's Android-only privacy `InAppWebViewSettings` whenever `trackingProtectionEnabled` is true, and leave each at its native default (`null`) when false. These settings are serialized but ignored by the iOS/macOS/Linux plugins.

- `requestedWithHeaderOriginAllowList` SHALL be the empty set (suppresses the `X-Requested-With: <package>` header for every origin).
- `attributionRegistrationBehavior` SHALL be `WebSettingsCompat.ATTRIBUTION_BEHAVIOR_DISABLED` (no Attribution Reporting source/trigger registration).
- `webViewMediaIntegrityApiStatus` SHALL be `WEBVIEW_MEDIA_INTEGRITY_API_ENABLED_WITHOUT_APP_IDENTITY`, not `DISABLED`: the integrity token stays available for legitimate site anti-fraud, but no longer carries this app's package/signing identity, closing the cross-site app-identity leak. This is independent of the protected-media (Widevine/EME) permission, which governs DRM playback rather than attestation.

#### Scenario: Umbrella on sets native privacy settings

**Given** a webview is constructed for a site with the umbrella on
**Then** `requestedWithHeaderOriginAllowList` is the empty set
**And** `attributionRegistrationBehavior` is the disabled constant
**And** `webViewMediaIntegrityApiStatus` is the enabled-without-app-identity constant

#### Scenario: Umbrella off leaves native defaults

**Given** a webview is constructed for a site with the umbrella off
**Then** `requestedWithHeaderOriginAllowList`, `attributionRegistrationBehavior`,
and `webViewMediaIntegrityApiStatus` are each `null`

---

### Requirement: ETP-023 - Protected content (DRM) denied under umbrella

The umbrella SHALL force the protected-content (Widevine/EME,
`PROTECTED_MEDIA_ID`) permission to deny — without showing the
Allow/Block popup — whenever `trackingProtectionEnabled` is true,
regardless of the stored per-site `protectedContentAllowed` value.
A granted request provisions a Widevine device identifier: a durable,
origin-readable device ID that survives the shim's fingerprint
randomization, data clears, and fingerprint rerolls (ETP-022), so
allowing it would defeat the rest of the umbrella. The stored
`protectedContentAllowed` value SHALL be preserved so turning the
umbrella off restores the user's remembered decision (mirroring
ETP-002's stored-value semantics). Android-only in effect, like the
permission itself.

#### Scenario: Stored allow, umbrella on

**Given** `protectedContentAllowed` is true and
`trackingProtectionEnabled` is true
**When** the site issues a `PROTECTED_MEDIA_ID` permission request
**Then** the request is denied
**And** no Allow/Block popup is shown
**And** the stored `protectedContentAllowed` remains true

#### Scenario: Stored ask, umbrella on

**Given** `protectedContentAllowed` is null (ask) and
`trackingProtectionEnabled` is true
**When** the site issues a `PROTECTED_MEDIA_ID` permission request
**Then** the request is denied without prompting
**And** the stored value remains null

#### Scenario: Umbrella off restores stored decision

**Given** `protectedContentAllowed` is true and
`trackingProtectionEnabled` is false
**When** the site issues a `PROTECTED_MEDIA_ID` permission request
**Then** the request is granted silently

#### Scenario: Nested webview denies too

**Given** the parent site has `trackingProtectionEnabled: true`
**When** a nested webview opened via `launchUrl` issues a
`PROTECTED_MEDIA_ID` permission request
**Then** the nested handler denies without prompting

#### Scenario: Settings UI reflects forcing

**Given** `trackingProtectionEnabled` is true on the site Permissions
screen
**Then** the Protected content row reads "Blocked"
**And** the row is inert, not tappable
**And** its subtitle names Tracking Protection as the reason

---

### Requirement: ETP-024 - Third-party cookies forced off under umbrella

The umbrella SHALL force `thirdPartyCookiesEnabled` to behave as false
whenever `trackingProtectionEnabled` is true, regardless of the stored
per-site value. Third-party cookies are the oldest cross-site tracking
channel, and leaving them reachable while the umbrella blocks tracker
requests, strips tracking parameters and randomises fingerprints would
be the umbrella's largest remaining hole.

This is the one subordinate the umbrella forces *off* rather than on.
ETP-002's four subordinates are block-lists whose failure mode is a
missing page element; third-party cookies additionally carry sign-in
redirects and embedded checkouts, so the stored value SHALL be preserved
and restored when the umbrella goes off (mirroring ETP-002 and ETP-023).

The forcing SHALL be derived on `WebViewModel` as
`effectiveThirdPartyCookiesEnabled`, and every path that hands the value
to a webview SHALL read that getter rather than the stored field:
`WebViewConfig` construction, `WebViewController.setOptions`, the
third-party cookie sweep in `onCookiesChanged`, and both `launchUrl`
call sites. The nested `InAppWebViewScreen` SHALL apply the same forcing
to the config it builds, as it already does for ETP-002's four.

#### Scenario: Stored enabled, umbrella on

**Given** `thirdPartyCookiesEnabled` is true and
`trackingProtectionEnabled` is true
**When** the webview is constructed
**Then** the `WebViewConfig` has `thirdPartyCookiesEnabled: false`
**And** the stored `thirdPartyCookiesEnabled` remains true
**And** a settings export still records the stored true

#### Scenario: Umbrella off restores the stored value

**Given** `thirdPartyCookiesEnabled` is true and
`trackingProtectionEnabled` is false
**When** the webview is constructed
**Then** the `WebViewConfig` has `thirdPartyCookiesEnabled: true`

#### Scenario: Nested webview forces too

**Given** the parent site has `trackingProtectionEnabled: true` and
`thirdPartyCookiesEnabled: true`
**When** a cross-domain link opens a nested `InAppWebViewScreen`
**Then** the nested `WebViewConfig` has `thirdPartyCookiesEnabled: false`

#### Scenario: Privacy UI reflects forcing

**Given** `trackingProtectionEnabled` is true on the site Privacy screen
**Then** the Third-party cookies `SwitchListTile` shows `value: false`
**And** its `onChanged` is `null`
**And** its subtitle reads "Forced off by Tracking Protection", the one
forced row that captions itself (ETP-017)

---

## Implementation Details

### Shim seeding

```dart
// lib/services/anti_fingerprinting_shim.dart
String buildAntiFingerprintingShim(String seed) {
  final encodedSeed = jsonEncode(seed);
  return '''(function() { /* ... */ var SEED = $encodedSeed; /* ... */ })();''';
}
```

The seed is the per-site `siteId`. JS-side, the seed is hashed via
FNV-1a 32-bit, then a Mulberry32 PRNG is constructed per call site
salted by a string describing the call (for example,
`'canvas2d:gid:0:0:64:64'` for a 64×64 `getImageData`). Salting per
call site means a fingerprinter cannot cancel the noise by reading the
same buffer twice — different calls get different sub-streams.

### WebViewConfig forcing

In `WebViewModel.getWebView` (and mirrored in `InAppWebViewScreen.initState`
for nested webviews), the effective values are:

```dart
clearUrlEnabled: clearUrlEnabled || trackingProtectionEnabled,
dnsBlockEnabled: dnsBlockEnabled || trackingProtectionEnabled,
contentBlockEnabled: contentBlockEnabled || trackingProtectionEnabled,
localCdnEnabled: localCdnEnabled || trackingProtectionEnabled,
thirdPartyCookiesEnabled: effectiveThirdPartyCookiesEnabled,
trackingProtectionEnabled: trackingProtectionEnabled,
```

`effectiveThirdPartyCookiesEnabled` inverts (ETP-024):

```dart
bool get effectiveThirdPartyCookiesEnabled =>
    trackingProtectionEnabled ? false : thirdPartyCookiesEnabled;
```

The stored `WebViewModel` field is unchanged; only the `WebViewConfig`
that flows into the platform webview sees the forced values.

### Shim injection

In `WebViewFactory.createWebView`
([lib/services/webview.dart](../../../lib/services/webview.dart)), the
shim is added to the `userScripts` list right after the always-on
do-not-track shim:

```dart
if (config.trackingProtectionEnabled && config.siteId != null) {
  userScripts.add(inapp.UserScript(
    groupName: 'anti_fingerprinting',
    source: '${buildAntiFingerprintingShim(config.siteId!)}\n;null;',
    injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: false,
  ));
}
```

### Backup integrity

`trackingProtectionEnabled` is a per-site field on `WebViewModel.toJson`,
so it rides through the settings backup path automatically — no entry
in `kExportedAppPrefs` is needed.

---

## Files

### Created
- `lib/services/anti_fingerprinting_shim.dart` — Pure-Dart shim builder.
- `test/anti_fingerprinting_shim_test.dart` — Dart shape tests.
- `test/js/anti_fingerprinting_shim.test.js` — Node + jsdom behavioural tests.
- `test/js_fixtures/anti_fingerprinting/shim_seed_alpha.js`
- `test/js_fixtures/anti_fingerprinting/shim_seed_beta.js`
- `openspec/specs/tracking-protection/spec.md` — This spec.
- `lib/screens/site_privacy.dart` — The Privacy screen (ETP-017):
  `SitePrivacyValues` plus the umbrella card and its three groups.
- `test/site_privacy_screen_test.dart` — Forcing and grouping tests.
- `test/js/tracking_protection_umbrella_funnel.test.js` — Structural gate:
  no path may hand a webview the stored value of a forced setting.

### Modified
- `lib/web_view_model.dart` — Added `trackingProtectionEnabled` field,
  serialisation, getWebView forcing, propagation through `launchUrlFunc`
  typedef and both nested-launch sites. Added `letterboxEnabled` +
  `spoofWindowWidth` / `spoofWindowHeight` (ETP-020/021) and
  `fingerprintResetNonce` (ETP-022) with the same serialisation +
  propagation, plus `rerollFingerprint`.
  `effectiveProtectedContentAllowed` forces deny under the umbrella
  (ETP-023); `effectiveThirdPartyCookiesEnabled` forces third-party
  cookies off under it (ETP-024).
- `lib/services/webview.dart` — Added `trackingProtectionEnabled` to
  `WebViewConfig`, shim injection. Added `letterboxEnabled` /
  `spoofWindowWidth` / `spoofWindowHeight` / `fingerprintResetNonce` to
  `WebViewConfig`; `_applyLetterbox` wraps the WebView; `letterbox` +
  `resetNonce` threaded into `buildAntiFingerprintingScriptSource`.
- `lib/services/letterbox.dart` — Pure `computeLetterboxTarget` grid-snap
  logic (ETP-020/021).
- `lib/services/anti_fingerprinting_shim.dart` — Letterbox-mode
  `screen.*`-mirrors-`window.inner*` (ETP-020); `resetNonce` folded into
  the seed (ETP-022).
- `lib/screens/site_privacy.dart` — "Letterbox window" switch under
  Tracking Protection, gated on the umbrella.
- `lib/main.dart` — Added `trackingProtectionEnabled` to `launchUrl`
  signature and the `InAppWebViewScreen` construction.
- `lib/screens/inappbrowser.dart` — Added `trackingProtectionEnabled`
  ctor field, mirrored forcing into the nested `WebViewConfig`; nested
  protected-media handler denies under the umbrella (ETP-023).
- `lib/screens/settings.dart` — The privacy tiles moved out to
  `site_privacy.dart` (ETP-017), leaving a summary row that opens it;
  what remains on the screen is grouped under Content / Behaviour /
  Network headings. Protected content moved earlier to the permissions
  screen (ETP-023).
- `tool/dump_shim_js.dart` — Two pinned-seed fixtures.
- `test/web_view_model_test.dart` — Round-trip + default tests for the
  new field.

---

## Testing

### Unit / shape

```bash
fvm flutter test test/anti_fingerprinting_shim_test.dart
fvm flutter test test/web_view_model_test.dart
fvm flutter test test/site_privacy_screen_test.dart
fvm flutter test test/js_fixtures_drift_test.dart
```

### jsdom behavioural

```bash
npm run test:js -- test/js/anti_fingerprinting_shim.test.js
```

### What jsdom CAN'T cover

jsdom omits real Canvas/WebGL/Audio engines. Tests stub these with inert
classes that record calls; they assert wrapper shape (prototype methods
replaced, `[native code]` toString, return value transformed) rather
than the noise's effect on real engine output. Real-engine fingerprint
proofing runs under Puppeteer + FingerprintJS in
`test/browser/fingerprint_real_engine.test.js`, with CreepJS-style
lie-detection probes in `test/browser/lie_detection.test.js`.
