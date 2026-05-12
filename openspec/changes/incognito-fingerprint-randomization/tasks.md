## 1. Launch nonce service

- [ ] 1.1 Create `lib/services/launch_nonce.dart` exposing `LaunchNonce.value` (lazy-initialised hex string from `Random.secure`, 16 bytes / 32 hex chars), `LaunchNonce.overrideForTesting(String?)`, and `LaunchNonce.resetForTesting()`.
- [ ] 1.2 Create `test/launch_nonce_test.dart` covering: (a) two reads within a process return the same value; (b) the value is non-empty hex; (c) `overrideForTesting` is honoured and `resetForTesting` clears it.

## 2. Seed derivation helper

- [ ] 2.1 Add `computeAntiFingerprintingSeed({required String siteId, required bool incognito, required String launchNonce})` to `lib/services/anti_fingerprinting_shim.dart`. Returns `'$siteId:$launchNonce'` when `incognito` is true, otherwise `siteId`.
- [ ] 2.2 Extend `test/anti_fingerprinting_shim_test.dart` with a `computeAntiFingerprintingSeed` group covering: non-incognito returns siteId verbatim; incognito mixes the nonce; same (siteId, nonce) → same seed; different nonces → different seeds; different siteIds → different seeds.

## 3. Wire into the shim-injection site

- [ ] 3.1 In `lib/services/webview.dart` (`WebViewFactory.createWebView`, ~line 1326), replace `buildAntiFingerprintingShim(config.siteId!)` with `buildAntiFingerprintingShim(computeAntiFingerprintingSeed(siteId: config.siteId!, incognito: config.incognito, launchNonce: LaunchNonce.value))`.
- [ ] 3.2 Update the inline comment block above the injection so it documents the incognito carve-out.

## 4. Spec

- [ ] 4.1 Add `openspec/changes/incognito-fingerprint-randomization/specs/tracking-protection/spec.md` with MODIFIED ETP-004 (incognito carve-out) and ADDED ETP-019 (launch-nonce contract).

## 5. Verification

- [ ] 5.1 `fvm flutter test test/anti_fingerprinting_shim_test.dart test/launch_nonce_test.dart`
- [ ] 5.2 `fvm flutter analyze`
