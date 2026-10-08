# JS Shim Tests Specification

## Purpose

Prove behaviourally — not just by string match — that the JavaScript
shims this app injects into webviews (desktop mode, location, language,
…) actually mutate the JS surface a real browser would expose. A typo in
`Object.defineProperty`, a wrong `Navigator.prototype` target, or a
broken `matchMedia` wrapper passes a substring check and silently breaks
in production.

## Status

- **Status**: Implemented
- **Platforms**: Cross-platform (runs on the Node test runner — no
  device or emulator required)
- **CI Integration**: GitHub Actions (`build-and-test.yml` →
  `js-shim-tests` job)

---

## Layered design

1. **Script** (`lib/js/<name>.js`) — the JavaScript itself, as a file.
   A value it needs is a `CONFIG.<key>` read. Code several scripts share
   is a part (`lib/js/_<name>.js`) pulled in by a `// @include <file>`
   line; a part includes no other part.
2. **Loader** (`PageJs`, `lib/services/page_js.dart`) — one enum value
   per script, read from the asset bundle once at startup. `script`
   returns a script that reads no `CONFIG`; `withConfig({...})` runs one
   with its config bound to `CONFIG` as a JSON literal, the only way a
   value reaches a page script. The builders in `lib/services/` turn a
   site's settings into that config.
3. **Tests**, in three layers:
   - **Dart** (`test/*_test.dart`) — the config each builder derives
     from a site's settings, and `PageJs`'s own contract
     (`test/page_js_test.dart`). Tests read `lib/js` from the checkout
     through `test/flutter_test_config.dart`.
   - **Tier 1 — jsdom** (`test/js/*.test.js`) — `helpers/page_js.js`
     reads the same file the same way (`pageJs(name, config)`), the
     test runs it inside `jsdom` and asserts the post-injection state of
     `navigator`, `window`, `Intl`, and the wrapped constructors. Cheap
     and fast; covers shim *shape*. Needs no Flutter SDK. Run with
     `npm run test:js`.
   - **Tier 2 — real Chromium** (`test/browser/*.test.js`) — loads the
     same script into headless Chromium via Puppeteer's
     `page.evaluateOnNewDocument` (mirroring DOCUMENT_START injection
     in the production WebView) and asserts behaviour the real engine
     produces: `matchMedia` against the live CSS engine, real
     `Intl.DateTimeFormat` timezone arithmetic with DST,
     `Date.prototype.getTimezoneOffset` for instants in different
     halves of the year, real `Geolocation` callback-style API, real
     `RTCPeerConnection` constructor semantics, and real CSP
     enforcement of `connect-src`. Boots Chromium per file (~1-2s) and
     adds ~5s wall time total. Run with `npm run test:browser`.

Nothing is generated or committed between the script and its tests:
both tiers read `lib/js` itself.

---

## Requirements

### Requirement: SHIM-TEST-001 — A page script is a file both sides read alike

Every script the app runs in a page MUST be a file under `lib/js/` read
through `PageJs`, and a value MUST reach it only as `withConfig` JSON.
The Node tiers MUST read `lib/js` by the same include rule and the same
`CONFIG` wrapper.

#### Scenario: A script written as a Dart string fails CI

- **GIVEN** a Dart file under `lib/` holds a multi-line string literal
  that reads as JavaScript
- **WHEN** `npm run test:js` runs `test/js/page_js.test.js`
- **THEN** the test fails naming the file and line

#### Scenario: A config that misses or adds a key fails at the loader

- **GIVEN** a script reads `CONFIG.language`
- **WHEN** a builder calls `withConfig` without that key, or with a key
  the script never reads
- **THEN** `PageJs.withConfig` fails its assert, in every debug run and
  every test that builds the script

#### Scenario: The two readers cannot drift apart

- **GIVEN** the include rule or the `CONFIG` wrapper changes in
  `lib/services/page_js.dart`
- **WHEN** `test/js/page_js.test.js` runs
- **THEN** it fails until `test/js/helpers/page_js.js` changes with it

---

### Requirement: SHIM-TEST-002 — Behavioural tests run the real script

Node-side tests MUST execute the script the production webview sees, not
a copy or paraphrase.

#### Scenario: Test loads a script by name

- **GIVEN** a Node test file `test/js/<shim>.test.js`
- **WHEN** the test calls `loadShim(pageJs('<name>', config), opts)`
- **THEN** the helper reads `lib/js/<name>.js` with its parts in place,
  binds `config` the way `PageJs.withConfig` does, and `eval`s it inside
  a fresh jsdom realm

#### Scenario: Polyfilled APIs are minimal stubs only

- **GIVEN** a shim wraps a browser API jsdom does not implement
  (`matchMedia`, `Geolocation`, `RTCPeerConnection`)
- **WHEN** the helper calls `installBrowserPolyfills(window)` on a
  fresh dom
- **THEN** the missing API is filled with an inert default — `matches:
  false` for matchMedia, no-op `getCurrentPosition` for Geolocation, a
  config-recording RTCPeerConnection — so the shim's `if (origFn)`
  guards see a real function to wrap
- **AND** the test asserts the **shape** of the resulting override
  (constructor replaced, getter defined, property set), not real-engine
  behaviour the polyfill cannot simulate

---

### Requirement: SHIM-TEST-003 — All three layers gate CI

CI MUST fail when any of the three layers breaks: the Dart tests, a
Tier 1 jsdom test (Node), or a Tier 2 real-Chromium test (Node +
Puppeteer).

#### Scenario: Every script parses as it is injected

- **GIVEN** a script under `lib/js/` with a syntax error, after its
  parts are included and its `CONFIG` wrapper applied
- **WHEN** `npm run test:js` runs `test/js/page_js.test.js`
- **THEN** the test for that script fails

#### Scenario: Every script passes ESLint as injected

- **GIVEN** a script under `lib/js/` that reads a name nothing defines,
  after its parts are included and its `CONFIG` wrapper applied
- **WHEN** `npm run test:js` runs `test/js/page_js_lint.test.js`
- **THEN** ESLint's `no-undef` fails the test for that script; the
  worker payload is one script of concatenated IIFEs, so such a
  `ReferenceError` would silence every shim after it

#### Scenario: The test code passes ESLint

- **GIVEN** a file under `test/js/` or `test/browser/` that reads a
  name nothing defines, or writes code it runs in a page, worker or
  jsdom realm as a multi-line template rather than a function
- **WHEN** `npm run test:js` runs `test/js/test_js_lint.test.js` with
  `eslint.config.js`
- **THEN** the test fails, naming the file and line
- **AND** an HTML page a test serves keeps its script tags

#### Scenario: Node tests run early in the Build Linux job

- **GIVEN** the `Build Linux` CI job
- **WHEN** the job has finished container apt-install and checkout
- **THEN** it runs `npm ci && npm run test:js` *before* the Flutter
  build step, so a shim regression fails without waiting on
  `flutter build linux`
- **AND** the Node test step does not depend on the Flutter SDK or any
  WPE / GTK package being functional — only on Node, npm, and the
  jsdom dependency chain being installed

#### Scenario: Real-Chromium tests run in the validate job

- **GIVEN** the `validate` CI job has restored the Puppeteer Chromium
  cache and run `npx puppeteer browsers install chrome`
- **WHEN** it runs `npm run test:browser`
- **THEN** every `test/browser/**/*.test.js` file boots Chromium via
  Puppeteer and asserts post-injection state under the real engine
- **AND** the test files set `requireBrowser` to hard-fail under
  `CI=true` when Chromium cannot launch — silently skipping the tier
  on a misconfigured runner would defeat its purpose

---

### Requirement: SHIM-TEST-004 — Adding a new script is one file and one value

Bringing a new script under the pipeline MUST take a file under
`lib/js/` and a `PageJs` value, and nothing in either test tier's
plumbing.

#### Scenario: Add a new script

- **GIVEN** a new file `lib/js/xyz.js`
- **WHEN** the developer adds `xyz('xyz')` to `PageJs`
- **THEN** the app loads it at startup, and once its sample config is in
  `test/js/helpers/page_js_samples.js` the parse, lint and rootless-document
  gates cover it
- **AND** a new `test/js/<xyz>.test.js` can run it with
  `pageJs('xyz', config)` without changes to `helpers/load_shim.js`
  (unless a new browser API needs polyfilling)
- **AND** a new `test/browser/<xyz>_real.test.js` can load the same
  script via `pageJs(...)` from `test/browser/helpers/launch.js` and
  run it against headless Chromium without touching the harness

#### Scenario: A file without a value fails

- **GIVEN** a file under `lib/js/` that no `PageJs` value names and no
  script includes
- **WHEN** `flutter test test/page_js_test.dart` runs
- **THEN** the test fails: the file would never be injected

---

### Requirement: SHIM-TEST-005 — Real-engine validation for engine-dependent surfaces

Shims that wrap APIs whose behaviour jsdom cannot honestly simulate (real CSS `matchMedia`, `Intl.DateTimeFormat` arbitrary IANA timezones, `Date.prototype.getTimezoneOffset` DST arithmetic, `Date.prototype.toString` zone formatting, `Geolocation` callback path, `RTCPeerConnection` constructor and SDP semantics, real Content-Security-Policy `connect-src` enforcement, `getUserMedia` + canvas `captureStream` producing a decodable video frame) MUST also have a Tier 2 test under `test/browser/<shim>_real.test.js` that loads the **same script** and asserts post-injection state under headless Chromium. Tier 2 covers behaviours, not just shapes; if jsdom can produce the same answer, the assertion belongs in Tier 1.

#### Scenario: matchMedia overrides asserted under the real CSS engine

- **GIVEN** the desktop_mode shim is loaded into a Chromium page
- **WHEN** the test queries `matchMedia('(pointer: coarse)')`
- **THEN** the result is `{matches: false}` — the shim's forced
  answer, not jsdom's permanent stub
- **AND** `matchMedia('(min-width: 1000px)')` against a 1280px
  viewport returns `{matches: true}` from the real engine because
  the shim does NOT hijack non-pointer / non-hover queries

#### Scenario: getTimezoneOffset returns DST-correct values

- **GIVEN** the location_spoof shim is loaded with TZ "Europe/Paris"
- **WHEN** the test calls `new Date('2024-01-15T12:00:00Z').getTimezoneOffset()`
- **THEN** the result is `-60` (CET, winter)
- **AND** `new Date('2024-07-15T12:00:00Z').getTimezoneOffset()`
  returns `-120` (CEST, summer)

#### Scenario: WebRTC relay branch rewrites configuration and SDP

- **GIVEN** a fake `RTCPeerConnection` is installed via
  `evaluateOnNewDocument` BEFORE the shim runs
- **AND** the location_spoof shim's relay branch wraps it
- **WHEN** the test creates a peer with
  `{iceTransportPolicy: 'all'}` and calls `setLocalDescription` with
  an SDP containing `a=candidate:` lines for both `typ host` and
  `typ relay`
- **THEN** the underlying fake's constructor receives
  `iceTransportPolicy: 'relay'`
- **AND** the SDP forwarded to the underlying `setLocalDescription`
  contains only the relay candidate; host and srflx lines are
  removed

#### Scenario: Geolocation getCurrentPosition resolves to spoofed coords

- **GIVEN** the location_spoof shim is loaded with
  `(35.6762, 139.6503, 25.0)`
- **WHEN** the test calls `navigator.geolocation.getCurrentPosition`
  and awaits the success callback
- **THEN** the position's `coords.latitude` and `coords.longitude`
  are within the configured sub-meter jitter (`±0.00001`) of
  `35.6762` and `139.6503`
- **AND** `navigator.permissions.query({name: 'geolocation'})`
  resolves to `{state: 'granted'}` so a site that gates on the
  permission still calls `getCurrentPosition`

#### Scenario: Function.prototype.toString hardening defeats native-stub probes

- **GIVEN** the location_spoof shim is loaded
- **WHEN** the test calls
  `Function.prototype.toString.call(navigator.geolocation.getCurrentPosition)`
- **THEN** the result is the string
  `"function getCurrentPosition() { [native code] }"`, not the
  shim's actual source — fingerprinters that probe via this method
  see the override as native

---

### Requirement: SHIM-TEST-006 — Tier 2 boots a per-file Chromium with documented timing

Tests under `test/browser/` MUST boot a fresh Chromium process per
file via `setupBrowser()` and inject the script via
`page.evaluateOnNewDocument`, which is the closest Puppeteer analogue
to a production WebView's DOCUMENT_START injection point.

#### Scenario: Per-file browser with shared launch harness

- **GIVEN** a Tier 2 test file calls `setupBrowser()` at module load
- **WHEN** node:test runs
- **THEN** `before` launches a headless Chromium with
  `--no-sandbox --disable-setuid-sandbox`
- **AND** `after` closes it, so each test file is isolated from the
  next

#### Scenario: Pre-injection hooks run before the shim

- **GIVEN** a test needs to observe what the shim's relay-branch
  wrapper passes to the underlying `RTCPeerConnection`
- **WHEN** the test passes a `preInit` script to `withShim(...)`
- **THEN** the harness registers the pre-init script via
  `page.evaluateOnNewDocument` BEFORE the shim, so the shim's
  `_RealRTC = window.RTCPeerConnection` capture sees the test's fake
  rather than Chromium's real `RTCPeerConnection`

#### Scenario: Documented Puppeteer-vs-WebView timing mismatch

- **GIVEN** the shim guards `MutationObserver.observe` on
  `if (document.documentElement)`
- **AND** Puppeteer's `evaluateOnNewDocument` fires before
  `document.documentElement` is created (real WKWebView /
  Android WebView Profile / WPE WebKit DOCUMENT_START runs after the
  element exists, so production timing differs)
- **WHEN** a Tier 2 test exercises the `MutationObserver` path under
  Puppeteer
- **THEN** it injects the shim post-`load` via `page.evaluate(...)`
  rather than via `evaluateOnNewDocument`, so the rewrite logic can
  be exercised without depending on the Puppeteer-specific
  injection-time behaviour
- **AND** a comment in the test acknowledges the difference so the
  reason the test diverges from the production injection model is
  not lost

---

### Requirement: SHIM-TEST-007 — Real-fingerprinter validation

Shims that target a fingerprintable surface (`navigator.platform`, `Intl` timezone, `navigator.maxTouchPoints`, etc.) MUST also have a Tier 3 test under `test/browser/fingerprint_real_engine.test.js` that loads a real, off-the-shelf fingerprint detector (`@fingerprintjs/fingerprintjs`) into the same Chromium and asserts the detector's `components` map reports the spoofed value. Tier 3 closes the loop between "shim installs the override" (Tier 1/2) and "a real fingerprinter would actually read what we forged".

#### Scenario: FingerprintJS reads the spoofed platform

- **GIVEN** the desktop_mode script for a Windows UA is loaded into a
  headless Chromium running on Linux
- **WHEN** the test injects the FingerprintJS UMD bundle via
  `page.addScriptTag` and calls `FingerprintJS.load().then(fp =>
  fp.get())`
- **THEN** `result.components.platform.value` is `"Win32"` — proving
  the shim's value reaches the detector via the same code path a
  fingerprinting site would use, not just our own `navigator.platform`
  read

#### Scenario: FingerprintJS reads the spoofed timezone

- **GIVEN** the location_spoof script with a Paris fix, zone and
  relay-only WebRTC is loaded
- **WHEN** the test runs FingerprintJS
- **THEN** `result.components.timezone.value` is `"Europe/Paris"`
- **AND** no `components.<spoofed-source>.error` is set — the shim
  must not throw mid-source under FingerprintJS's code path

---

### Requirement: SHIM-TEST-008 — Lie-detection probes

Tier 3 MUST also include CreepJS-style probes under `test/browser/lie_detection.test.js` that try to *detect that the surface was spoofed* — `Function.prototype.toString.call(fn)` reading the override's source, `Object.getOwnPropertyNames(navigator)` listing the override as an own-property, iframe-prototype escape, descriptor-getter inspection. Probes that the current shim withstands SHALL be encoded as live assertions. Probes that the current shim fails MAY be encoded with the `todo` flag and a comment documenting the hardening required to flip them to passing — so a future hardening pass converts the marker to a green test rather than rewriting the assertion. When the hardening lands, the `todo` flag SHALL be removed and any paired "premise check" test SHALL be deleted.

#### Scenario: Native-code probe passes against location_spoof

- **GIVEN** the location_spoof shim is loaded
- **WHEN** the test calls
  `Function.prototype.toString.call(navigator.geolocation.getCurrentPosition)`
- **THEN** the result matches `[native code]` — the shim's WeakMap-
  keyed `Function.prototype.toString` patch defeats the probe
- **AND** the same check passes for `Date.prototype.getTimezoneOffset`,
  `Geolocation.prototype.getCurrentPosition`, `Intl.DateTimeFormat`,
  and `Function.prototype.toString` itself

#### Scenario: Iframe inherits the spoofed surface

- **GIVEN** any shim is loaded via `evaluateOnNewDocument` (which
  registers the script for every frame, mirroring
  `forMainFrameOnly: false`)
- **WHEN** the test creates a child iframe and reads
  `iframe.contentWindow.navigator.platform` (or the timezone via
  the iframe's `Intl`)
- **THEN** the iframe-realm value matches the spoofed value — a site
  cannot escape the shim by minting a fresh iframe and reading
  through its contentWindow

#### Scenario: desktop_mode shim survives all lie probes

- **GIVEN** the desktop_mode shim is loaded
- **WHEN** the test reads
  `Object.getOwnPropertyNames(navigator)` and the
  `Object.getOwnPropertyDescriptor(Navigator.prototype, 'platform').get`
  source via `Function.prototype.toString`
- **THEN** the navigator carries no own-property leak (the shim
  patches `Navigator.prototype`, not the instance) and the getter
  source returns `[native code]` (the shared
  `Function.prototype.toString` WeakMap stub from
  `window.__wsFnStubs`, installed by every shim that wraps a
  function, defeats the probe)
- **AND** `'ontouchstart' in window` is `false` (the shim deletes
  `ontouchstart` from `window` and `Window.prototype`, matching a
  genuine no-touch desktop browser)

#### Scenario: location_spoof, theme_color_scheme, blob_url_capture survive native-code probes

- **GIVEN** any of the location_spoof, theme_color_scheme, or
  blob_url_capture shims is loaded
- **WHEN** a fingerprinter calls `Function.prototype.toString` on
  any wrapped function (`URL.createObjectURL`, `URL.revokeObjectURL`,
  `window.matchMedia`, `Permissions.prototype.query`, every
  `Geolocation.prototype.*`, `Date.prototype.getTimezoneOffset`,
  `Intl.DateTimeFormat`)
- **THEN** the result matches `[native code]` — every wrapper is
  registered with `asNative(...)` against the shared WeakMap stub
- **AND** the shim does not leak as an own-property: the
  location_spoof shim patches `Permissions.prototype.query` (not
  `navigator.permissions.query`), so
  `Object.getOwnPropertyNames(navigator.permissions)` is `[]`

---

## Limits and future work

### Out of scope: canvas / WebGL / audio fingerprint defences

Tier 3 covers fingerprinter-readable values for the surfaces our
shims spoof. We do not currently ship canvas, WebGL, or AudioContext
fingerprint defences; if those ship, Tier 3 must grow assertions
against `result.components.canvas`, `webGlBasics`, and `audio`
similarly. CreepJS's deeper "engineLies" detection (looking at
prototype walks and getter source bytes) is out of scope unless we
add an explicit anti-detection requirement to the spoofing specs.

---

## Files

**Scripts covered** (`lib/js/`, through `PageJs`): every one, by the
parse gate; behaviourally, among others:
- `desktop_mode.js` (3 platforms) — Tier 1 + 2 + 3
- `location_spoof.js` (11 configs, `test/js/helpers/location_configs.js`)
  — Tier 1 + 2 + 3
- `blob_url_capture.js`, `blob_download.js` — Tier 1 + 2 (CSP)
- `language.js` (3 lang codes) — Tier 1 + 2
- `theme_color_scheme.js` (3 theme values) — Tier 1 + 2

**Pipeline:**
- `lib/services/page_js.dart` — `PageJs`, the loader
- `test/flutter_test_config.dart` — loads `lib/js` for the Dart tests
- `test/page_js_test.dart` — the loader's contract
- `test/js/page_js.test.js` — parse gate, inline-JS gate, reader parity
- `test/js/page_js_lint.test.js` — ESLint over every script as injected
- `eslint.config.js`, `test/js/test_js_lint.test.js` — ESLint over the
  test files themselves
- `test/js/helpers/script_of.js` — a test function as script text, for
  code that crosses into another realm as a string
- `test/js/helpers/page_js_samples.js` — one sample config per script
- `test/js/` — Tier 1 jsdom test files
- `test/js/helpers/page_js.js` — reads `lib/js` the way `PageJs` does
- `test/js/helpers/load_shim.js` — jsdom loader + polyfills
- `test/browser/` — Tier 2 real-Chromium + Tier 3 fingerprint test files
- `test/browser/helpers/launch.js` — Puppeteer harness +
  `requireBrowser` hard-fail on CI
- `test/browser/helpers/csp_server.js` — local HTTP server with
  CSP headers for the blob-capture tier-2 test
- `test/browser/fingerprint_real_engine.test.js` — Tier 3
  fingerprintjs assertions
- `test/browser/lie_detection.test.js` — Tier 3 CreepJS-style probes
  (Function.prototype.toString native-code, own-property enumeration,
  iframe-prototype escape, descriptor inspection)

**CI:**
- `.github/workflows/build-and-test.yml` — `js-shim-tests` job
  (Tier 1) + `validate` job (Tier 2 + 3 via `npm run test:browser`)
