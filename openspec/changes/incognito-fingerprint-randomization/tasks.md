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

## 5. Verification

- [ ] 5.1 `fvm flutter test test/anti_fingerprinting_shim_test.dart test/launch_nonce_test.dart`
- [ ] 5.2 `fvm flutter analyze`
