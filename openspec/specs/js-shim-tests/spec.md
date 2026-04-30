# JS Shim Tests Specification

## Purpose

Prove behaviourally — not just by string match — that the JavaScript
shims this app injects into webviews (`buildDesktopModeShim`,
`LocationSpoofService.buildScript`, …) actually mutate the JS surface a
real browser would expose. The Dart-side tests in `test/*_test.dart`
already assert that the *string output* of each builder contains the
expected substrings, but a typo in `Object.defineProperty`, a wrong
`Navigator.prototype` target, or a broken `matchMedia` wrapper passes
the substring check and silently breaks in production.

## Status

- **Status**: Implemented
- **Platforms**: Cross-platform (runs on the Node test runner — no
  device or emulator required)
- **CI Integration**: GitHub Actions (`build-and-test.yml` →
  `js-shim-tests` job)

---

## Layered design

The pipeline has three pieces, each with a separable responsibility:

1. **Builder** (`lib/services/*.dart`) — returns the shim as a Dart
   string at runtime, given per-site or per-feature parameters.
2. **Dumper** (`tool/dump_shim_js.dart`) — calls every builder with a
   curated set of scenarios and writes the resulting JS to
   `test/js_fixtures/<group>/<variant>.js`. Fixtures are committed.
3. **Tests**, in three layers:
   - **Drift check** (`test/js_fixtures_drift_test.dart`) — runs as
     part of `flutter test`, re-invokes the dumper's
     `buildAllFixtures()`, and fails if any committed fixture differs
     from the builder output. Forces fixtures to stay in lockstep with
     the builder.
   - **Tier 1 — jsdom** (`test/js/*.test.js`) — loads the fixture via
     `helpers/load_shim.js`, runs it inside `jsdom`, and asserts the
     post-injection state of `navigator`, `window`, `Intl`, and the
     wrapped constructors. Cheap and fast; covers shim *shape*. Run
     with `npm run test:js`.
   - **Tier 2 — real Chromium** (`test/browser/*.test.js`) — loads
     the same fixture into headless Chromium via Puppeteer's
     `page.evaluateOnNewDocument` (mirroring DOCUMENT_START injection
     in the production WebView) and asserts behaviour the real engine
     produces: `matchMedia` against the live CSS engine, real
     `Intl.DateTimeFormat` timezone arithmetic with DST,
     `Date.prototype.getTimezoneOffset` for instants in different
     halves of the year, real `Geolocation` callback-style API, real
     `RTCPeerConnection` constructor semantics, and real CSP
     enforcement of `connect-src`. Boots Chromium per file (~1-2s) and
     adds ~5s wall time total. Run with `npm run test:browser`.

The dumper is the only place a new shim has to be registered. Adding a
new fixture adds a new test target automatically (via the drift check
loop) and surfaces a new file for `*.test.js` and `*.test.js`-tier-2
authors to assert against.

---

## Requirements

### Requirement: SHIM-TEST-001 — Fixtures track the builder

Every shim covered by this pipeline MUST have a committed fixture under
`test/js_fixtures/` that is byte-identical to the JS string the runtime
builder produces.

#### Scenario: Builder change without fixture refresh fails CI

- **GIVEN** a developer edits a shim builder in `lib/services/`
- **AND** the developer has not run `fvm dart run tool/dump_shim_js.dart`
- **WHEN** `fvm flutter test test/js_fixtures_drift_test.dart` runs
- **THEN** the test fails with a message naming the drifted fixture
- **AND** the message instructs the developer to run the dumper

#### Scenario: Refreshing fixtures restores green

- **GIVEN** a fixture is out of date
- **WHEN** the developer runs `fvm dart run tool/dump_shim_js.dart`
- **THEN** every registered fixture is rewritten to disk
- **AND** the drift check passes

---

### Requirement: SHIM-TEST-002 — Behavioural tests run the real shim string

Node-side tests under `test/js/` MUST execute the exact JS string the
production webview sees, not a copy or paraphrase.

#### Scenario: Test loads fixture by relative path

- **GIVEN** a Node test file `test/js/<shim>.test.js`
- **WHEN** the test calls `loadShim('<group>/<variant>.js', opts)`
- **THEN** the helper reads `test/js_fixtures/<group>/<variant>.js`
  from disk and `eval`s it inside a fresh jsdom realm

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

CI MUST fail when any of the three layers breaks: drift check (Dart),
Tier 1 jsdom test (Node), or Tier 2 real-Chromium test (Node +
Puppeteer).

#### Scenario: Drift check runs as part of flutter test

- **GIVEN** the `Build Android` CI job runs `fvm flutter test`
- **WHEN** the drift check fails for any fixture
- **THEN** the job fails

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

### Requirement: SHIM-TEST-004 — Adding a new shim is one extension point

Bringing a new shim under the test pipeline MUST be possible without
modifying the dumper's discovery logic, the drift test's iteration
logic, or the npm script.

#### Scenario: Add a new shim fixture

- **GIVEN** a new builder `buildXyzShim()` in `lib/services/`
- **WHEN** the developer adds an entry to `buildAllFixtures()` in
  `tool/dump_shim_js.dart`, runs the dumper, and commits the new file
- **THEN** the drift check covers the new fixture automatically (no
  test edit)
- **AND** a new `test/js/<xyz>.test.js` can load and assert against
  the new fixture without changes to `helpers/load_shim.js` (unless a
  new browser API needs polyfilling)
- **AND** a new `test/browser/<xyz>_real.test.js` can load the same
  fixture via `readFixture(...)` from `test/browser/helpers/launch.js`
  and run it against headless Chromium without touching the harness

---

### Requirement: SHIM-TEST-005 — Real-engine validation for engine-dependent surfaces

Shims that wrap APIs whose behaviour jsdom cannot honestly simulate (real CSS `matchMedia`, `Intl.DateTimeFormat` arbitrary IANA timezones, `Date.prototype.getTimezoneOffset` DST arithmetic, `Date.prototype.toString` zone formatting, `Geolocation` callback path, `RTCPeerConnection` constructor and SDP semantics, real Content-Security-Policy `connect-src` enforcement) MUST also have a Tier 2 test under `test/browser/<shim>_real.test.js` that loads the **same committed fixture** and asserts post-injection state under headless Chromium. Tier 2 covers behaviours, not just shapes; if jsdom can produce the same answer, the assertion belongs in Tier 1.

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
file via `setupBrowser()` and inject the fixture via
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

- **GIVEN** the desktop_mode `windows` fixture is loaded into a
  headless Chromium running on Linux
- **WHEN** the test injects the FingerprintJS UMD bundle via
  `page.addScriptTag` and calls `FingerprintJS.load().then(fp =>
  fp.get())`
- **THEN** `result.components.platform.value` is `"Win32"` — proving
  the shim's value reaches the detector via the same code path a
  fingerprinting site would use, not just our own `navigator.platform`
  read

#### Scenario: FingerprintJS reads the spoofed timezone

- **GIVEN** the location_spoof `full_combo` fixture is loaded
- **WHEN** the test runs FingerprintJS
- **THEN** `result.components.timezone.value` is `"Europe/Paris"`
- **AND** no `components.<spoofed-source>.error` is set — the shim
  must not throw mid-source under FingerprintJS's code path

---

### Requirement: SHIM-TEST-008 — Lie-detection probes

Tier 3 MUST also include CreepJS-style probes under `test/browser/lie_detection.test.js` that try to *detect that the surface was spoofed* — `Function.prototype.toString.call(fn)` reading the override's source, `Object.getOwnPropertyNames(navigator)` listing the override as an own-property, iframe-prototype escape, descriptor-getter inspection. Probes that the current shim withstands SHALL be encoded as live assertions; probes that the current shim fails SHALL be encoded with the `todo` flag and a comment documenting the hardening required to flip them to passing — so a future hardening pass converts the marker to a green test rather than rewriting the assertion.

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

#### Scenario: Known leaks documented as todo

- **GIVEN** the desktop_mode shim's `def(navigator, 'platform', getter)`
  pattern creates an own-property on `navigator` (real navigators
  carry `platform` only on `Navigator.prototype`)
- **WHEN** the lie-detection test asserts
  `Object.getOwnPropertyNames(navigator)` does NOT include `platform`
- **THEN** the test is marked `todo` with a comment recording the
  hardening required (target `Navigator.prototype` instead, or
  proxy-trap the navigator)
- **AND** a paired premise-check test asserts the leak IS currently
  observable, so when a hardening pass flips the todo to passing,
  the premise check fails simultaneously and signals "delete the
  todo marker too"

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

**Builders covered:**
- `lib/services/desktop_mode_shim.dart` (3 UA variants) — Tier 1 + 2 + 3
- `lib/services/location_spoof_service.dart` (5 configs) — Tier 1 + 2 + 3
- `lib/services/blob_url_capture_shim.dart` — Tier 1 + 2 (CSP)

**Pipeline:**
- `tool/dump_shim_js.dart` — fixture generator
- `test/js_fixtures/` — committed fixtures + README
- `test/js_fixtures_drift_test.dart` — Dart drift check
- `test/js/` — Tier 1 jsdom test files
- `test/js/helpers/load_shim.js` — jsdom loader + polyfills
- `test/browser/` — Tier 2 real-Chromium + Tier 3 fingerprint test files
- `test/browser/helpers/launch.js` — Puppeteer harness +
  `requireBrowser` hard-fail on CI
- `test/browser/helpers/csp_server.js` — local HTTP server with
  CSP headers for the blob-capture tier-2 test
- `test/browser/fingerprint_real_engine.test.js` — Tier 3
  fingerprintjs assertions
- `test/browser/lie_detection.test.js` — Tier 3 CreepJS-style probes
  with `todo` markers for known leaks

**CI:**
- `.github/workflows/build-and-test.yml` — `js-shim-tests` job
  (Tier 1) + `validate` job (Tier 2 + 3 via `npm run test:browser`)
