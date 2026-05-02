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
   font enumeration, screen dimensions, hardware concurrency, plugin
   lists, battery state, voice list, high-resolution timers, and
   element bounding boxes. None of these were addressed.

The umbrella addresses both: one switch, both behaviours.

## Solution

Add a per-site `trackingProtectionEnabled` boolean (default true) to
`WebViewModel`. When true:

* The four pre-existing toggles (`clearUrlEnabled`, `dnsBlockEnabled`,
  `contentBlockEnabled`, `localCdnEnabled`) behave as ON regardless of
  their stored value — `WebViewModel.getWebView` and
  `InAppWebViewScreen` compute `effective = stored ||
  trackingProtectionEnabled` and pass that to `WebViewConfig`.
* A JS shim
  ([lib/services/anti_fingerprinting_shim.dart](../../../lib/services/anti_fingerprinting_shim.dart))
  is injected at `DOCUMENT_START` into every frame of the site,
  patching the surfaces enumerated below seeded by the per-site
  `siteId`. Per-site stability + cross-site uniqueness is delivered by
  a Mulberry32 PRNG keyed off an FNV-1a hash of the seed.

When false, the four sub-toggles act independently as they did pre-
umbrella, the anti-fingerprinting shim is not injected, and per-site
fingerprinting protection is off.

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

#### Scenario: Settings UI reflects forcing

**Given** `trackingProtectionEnabled` is true on the site settings
screen
**Then** the ClearURLs / DNS / Content Blocker / LocalCDN
`SwitchListTile`s show `value: true`
**And** their `onChanged: null` (visually disabled)
**And** their subtitle reads "Forced on by Tracking Protection"

---

### Requirement: ETP-003 - Anti-fingerprinting shim injected

The system SHALL inject the JS shim from `lib/services/anti_fingerprinting_shim.dart` at `DOCUMENT_START` with `forMainFrameOnly: false` whenever `trackingProtectionEnabled` is true and the site has a `siteId`, so iframes are also covered.

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

#### Scenario: screen dimensions pinned

**Given** the shim is loaded under jsdom
**Then** `window.screen.width === 1920` and `window.screen.height === 1080`

#### Scenario: Overrides do NOT leak as own-properties

**Given** the shim is loaded
**Then** `Object.getOwnPropertyNames(navigator)` does NOT contain any
of `hardwareConcurrency`, `deviceMemory`, `plugins`, `mimeTypes`,
`getBattery`
**And** `Object.getOwnPropertyNames(screen)` does NOT contain `width`,
`height`, `colorDepth`, or `pixelDepth`

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

### Requirement: ETP-017 - Settings UI

The site Settings screen SHALL expose the umbrella as a `SwitchListTile`
labeled "Tracking Protection" with a subtitle of "Anti-fingerprinting +
force tracker blocking", placed above the four subordinate switches.
The subordinate switches SHALL render with `onChanged: null` and value
`true` whenever the umbrella is on, with subtitle "Forced on by Tracking
Protection". The LocalCDN subordinate is gated additionally by
`LocalCdnService.instance.hasCache` — its effective value is
`(stored || umbrella) && hasCache`, since it has no effect without a
populated cache.

#### Scenario: Umbrella switch placed above subordinates

**Given** the user opens the per-site Settings screen
**Then** a `SwitchListTile` titled "Tracking Protection" is shown
**And** it is rendered above the ClearURLs / DNS Blocklist / Content
Blocker / LocalCDN switches

#### Scenario: Subordinates disabled while umbrella is on

**Given** the umbrella is on
**Then** the ClearURLs, DNS Blocklist, and Content Blocker switches show
`value: true`
**And** the LocalCDN switch shows `value: true` when
`LocalCdnService.instance.hasCache` is true (otherwise `false`, since
the cache is empty)
**And** their `onChanged` is `null` (Material renders the switch grey)
**And** their subtitle reads "Forced on by Tracking Protection"

#### Scenario: Subordinates editable while umbrella is off

**Given** the umbrella is off
**Then** the four subordinate switches are tappable
**And** their values reflect the per-site stored booleans

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
trackingProtectionEnabled: trackingProtectionEnabled,
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

### Modified
- `lib/web_view_model.dart` — Added `trackingProtectionEnabled` field,
  serialisation, getWebView forcing, propagation through `launchUrlFunc`
  typedef and both nested-launch sites.
- `lib/services/webview.dart` — Added `trackingProtectionEnabled` to
  `WebViewConfig`, shim injection.
- `lib/main.dart` — Added `trackingProtectionEnabled` to `launchUrl`
  signature and the `InAppWebViewScreen` construction.
- `lib/screens/inappbrowser.dart` — Added `trackingProtectionEnabled`
  ctor field, mirrored forcing into the nested `WebViewConfig`.
- `lib/screens/settings.dart` — Umbrella `SwitchListTile` and grey-out
  for the three subordinates.
- `tool/dump_shim_js.dart` — Two pinned-seed fixtures.
- `test/web_view_model_test.dart` — Round-trip + default tests for the
  new field.

---

## Testing

### Unit / shape

```bash
fvm flutter test test/anti_fingerprinting_shim_test.dart
fvm flutter test test/web_view_model_test.dart
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
proofing belongs to a follow-up Playwright + CreepJS tier (not in scope
for this change).
