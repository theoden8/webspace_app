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
3. **Tests**, in two layers:
   - **Drift check** (`test/js_fixtures_drift_test.dart`) — runs as
     part of `flutter test`, re-invokes the dumper's
     `buildAllFixtures()`, and fails if any committed fixture differs
     from the builder output. Forces fixtures to stay in lockstep with
     the builder.
   - **Behavioural** (`test/js/*.test.js`) — loads the fixture via
     `helpers/load_shim.js`, runs it inside `jsdom`, and asserts the
     post-injection state of `navigator`, `window`, `Intl`, and the
     wrapped constructors. Run with `npm run test:js`.

The dumper is the only place a new shim has to be registered. Adding a
new fixture adds a new test target automatically (via the drift check
loop) and surfaces a new file for `*.test.js` authors to assert
against.

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

### Requirement: SHIM-TEST-003 — Both layers gate CI

CI MUST fail when either layer breaks: drift check (Dart) or
behavioural test (Node).

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

---

## Limits and future work

### Out of scope: real-engine fingerprinting

jsdom does not implement canvas, WebGL, audio context, or real CSS
layout. Shims that touch those surfaces (the WebGL kill-switch, any
future canvas-fingerprint defence) can only be tested for **shape** —
that the override is in place — not for whether a real fingerprinter
would be defeated.

### Future tier: Playwright + open-source detector

End-to-end privacy proofing belongs in a Playwright (or Puppeteer)
tier that loads each shim into headless Chromium via
`page.addInitScript()` and runs a real fingerprint detector
([CreepJS](https://github.com/abrahamjuliot/creepjs),
[fingerprintjs](https://github.com/fingerprintjs/fingerprintjs))
against it. That tier is not yet built; this spec covers Tier 1 only.

---

## Files

**Builders covered (Tier 1):**
- `lib/services/desktop_mode_shim.dart` (3 UA variants)
- `lib/services/location_spoof_service.dart` (5 configs)

**Pipeline:**
- `tool/dump_shim_js.dart` — fixture generator
- `test/js_fixtures/` — committed fixtures + README
- `test/js_fixtures_drift_test.dart` — Dart drift check
- `test/js/` — Node test files
- `test/js/helpers/load_shim.js` — jsdom loader + polyfills

**CI:**
- `.github/workflows/build-and-test.yml` — `js-shim-tests` job
