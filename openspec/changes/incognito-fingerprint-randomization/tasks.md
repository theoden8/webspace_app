## 1. Launch nonce service

- [ ] 1.1 Create `lib/services/launch_nonce.dart` exposing `LaunchNonce.value` (lazy-initialised hex string from `Random.secure`, 16 bytes / 32 hex chars), `LaunchNonce.overrideForTesting(String?)`, and `LaunchNonce.resetForTesting()`.
- [ ] 1.2 Create `test/launch_nonce_test.dart` covering: (a) two reads within a process return the same value; (b) the value is non-empty hex; (c) `overrideForTesting` is honoured and `resetForTesting` clears it.

## 2. Seed derivation helper

- [ ] 2.1 Add `computeAntiFingerprintingSeed({required String siteId, required bool incognito, required String launchNonce})` to `lib/services/anti_fingerprinting_shim.dart`. Returns `'$siteId:$launchNonce'` when `incognito` is true, otherwise `siteId`.
- [ ] 2.2 Extend `test/anti_fingerprinting_shim_test.dart` with a `computeAntiFingerprintingSeed` group covering: non-incognito returns siteId verbatim; incognito mixes the nonce; same (siteId, nonce) → same seed; different nonces → different seeds; different siteIds → different seeds.

## 3. Wire into the shim-injection site

- [ ] 3.1 Add `buildAntiFingerprintingScriptSource({siteId, trackingProtectionEnabled, incognito, launchNonce})` in `lib/services/anti_fingerprinting_shim.dart` returning `String?` — encapsulates the umbrella + siteId gate, the seed derivation, and the `\n;null;` evaluator-return contract, so the entire chain is exercisable from `flutter test`.
- [ ] 3.2 In `lib/services/webview.dart` (`WebViewFactory.createWebView`, ~line 1326), replace the direct `buildAntiFingerprintingShim(config.siteId!)` call with `buildAntiFingerprintingScriptSource(...)` driven by `LaunchNonce.value`; keep the inline comment block documenting the incognito carve-out.
- [ ] 3.3 Add a `fingerprint ephemerality (issue #327)` group in `test/anti_fingerprinting_shim_test.dart` (parallel to `incognito ephemerality (issue #298)` in `test/web_view_model_test.dart`) covering: TP off → no shim; TP on + null siteId → no shim; non-incognito identical across simulated launches; incognito differs across simulated launches; incognito stable within one launch; cross-site uniqueness preserved under a shared launch nonce; toggling incognito changes the fingerprint; `\n;null;` sentinel preserved.

## 4. Spec

- [ ] 4.1 Add `openspec/changes/incognito-fingerprint-randomization/specs/tracking-protection/spec.md` with MODIFIED ETP-004 (incognito carve-out) and ADDED ETP-019 (launch-nonce contract).

## 5. Tier 3 real-engine coverage

- [ ] 5.1 Add two pinned-seed fixtures to `tool/dump_shim_js.dart` —
      `anti_fingerprinting/shim_seed_alpha_launch_one.js` and
      `shim_seed_alpha_launch_two.js` — built via
      `computeAntiFingerprintingSeed(siteId: 'alpha-fixture-seed',
      incognito: true, launchNonce: 'nonce-launch-one' | 'nonce-launch-two')`.
- [ ] 5.2 Re-dump fixtures: `fvm dart run tool/dump_shim_js.dart`. The drift
      test in `test/js_fixtures_drift_test.dart` enforces these are in
      sync with the builders going forward.
- [ ] 5.3 Add a `#327 incognito fingerprint rerolls per launch` block in
      `test/browser/fingerprint_real_engine.test.js` asserting under
      headless Chromium + FingerprintJS: (a) two simulated launches with
      different nonces produce distinct `canvas` components for the same
      siteId; (b) the same shim loaded twice yields identical components
      (in-launch stability); (c) the non-incognito (siteId-only) shim
      differs from the incognito (siteId:nonce) shim for the same siteId.

## 6. Doc cleanup

- [ ] 6.1 Replace the stale "Playwright + CreepJS follow-up tier" phrasing
      in `lib/services/anti_fingerprinting_shim.dart`,
      `openspec/specs/tracking-protection/spec.md`,
      `test/js/anti_fingerprinting_shim.test.js`,
      `test/js/helpers/load_shim.js`, and `test/js_fixtures/README.md`.
      The Tier 3 harness already exists and runs under Puppeteer +
      FingerprintJS; the leftover "follow-up tier" comments predate it.

## 7. Verification

- [ ] 7.1 `fvm flutter test test/anti_fingerprinting_shim_test.dart test/launch_nonce_test.dart test/js_fixtures_drift_test.dart`
- [ ] 7.2 `npm run test:browser -- test/browser/fingerprint_real_engine.test.js`
- [ ] 7.3 `fvm flutter analyze` (no new issues from changed files)
