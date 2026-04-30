# JS shim fixtures

These files are the *exact* JavaScript that the app's shim builders
(`lib/services/desktop_mode_shim.dart`, `lib/services/location_spoof_service.dart`,
…) emit at runtime, dumped to disk so Node-side tests
(`test/js/*.test.js`) can run them inside jsdom.

## Workflow

1. Change a shim builder in `lib/`.
2. Refresh fixtures:
   ```
   fvm dart run tool/dump_shim_js.dart
   ```
3. Run the Dart drift check (also runs as part of `fvm flutter test`):
   ```
   fvm flutter test test/js_fixtures_drift_test.dart
   ```
4. Run the Node-side behavioural tests:
   ```
   npm ci          # first time only
   npm run test:js
   ```
5. Commit the regenerated fixtures alongside your shim change.

`tool/dump_shim_js.dart --check` exits non-zero if any fixture is out of
date — useful in pre-commit hooks.

## Adding a new shim

1. Make the builder reachable from pure Dart (no Flutter widget imports).
2. Add an entry to `buildAllFixtures()` in `tool/dump_shim_js.dart`.
3. Run the dumper. A new file appears under `test/js_fixtures/`.
4. Add a `*.test.js` under `test/js/` that loads the fixture via
   `helpers/load_shim.js` and asserts the expected post-injection state.

## Scope and limits (read before writing tests)

- jsdom is **not a real browser**. Anything backed by canvas, WebGL,
  audio context, or real CSS layout cannot be exercised here. Polyfill
  what the shim wraps (helper installs `matchMedia`, `Geolocation`,
  `RTCPeerConnection` stubs) and assert the **shape** of the override —
  constructors replaced, getters defined, properties set — not against
  real-engine behaviour.
- For end-to-end privacy proofing (does the shim actually hide what
  fingerprinters see?), a Tier 2 setup using Playwright + an open-source
  detector like [CreepJS](https://github.com/abrahamjuliot/creepjs) or
  [fingerprintjs/fingerprintjs](https://github.com/fingerprintjs/fingerprintjs)
  is the natural follow-up. That tier hasn't been built yet; the jsdom
  tests here only prove the patches install correctly.
