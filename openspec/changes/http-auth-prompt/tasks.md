## 1. Specify

- [x] 1.1 `specs/http-auth-prompt/spec.md`: HTTPAUTH-001 (router first),
  HTTPAUTH-002 (site hosts only), HTTPAUTH-003 (the dialog), HTTPAUTH-004
  (remembered per site; incognito read-only, archive-tier off), HTTPAUTH-005
  (retry), HTTPAUTH-006 (never leaves the device), HTTPAUTH-007 (real-engine
  tier, Linux gap).
- [x] 1.2 `specs/archive/spec.md`: the ARCH-006 matrix row.
- [x] 1.3 The `http-auth-prompt` row in the CLAUDE.md OpenSpec table, marked
  *(change)* until archived.

## 2. Engine and storage

- [x] 2.1 `lib/services/http_auth_engine.dart`: `HttpAuthSession`,
  `HttpAuthMemory`, `HttpAuthCredentialStore`. Pure, no Flutter.
- [x] 2.2 `lib/services/http_auth_secure_storage.dart`, serialized writes,
  malformed entries skipped.
- [x] 2.3 `test/http_auth_engine_test.dart`,
  `test/http_auth_secure_storage_test.dart` (includes the HTTPAUTH-006 export
  gate).

## 3. Wire it

- [x] 3.1 `answerHttpAuthChallenge` on the site webview and the popup;
  `WebViewConfig.onHttpAuthRequest` (PLUMBING) and `httpAuthMemory`
  (POSTURE) classified in `nested_webview_posture_parity.test.js`.
- [x] 3.2 `effectiveHttpAuthMemory` through `LaunchUrlFunc`, both call sites,
  `launchUrl`, `_launchNestedForModel` and `InAppWebViewScreen`.
- [x] 3.3 The dialog, `test/http_auth_prompt_test.dart`, and both l10n/design
  token gates.
- [x] 3.4 Saved sign-ins row in site settings.
- [x] 3.5 Orphan sweep target plus the post-import and post-delete GC sites.

## 4. Real engines

- [x] 4.1 `integration_test/http_auth_test.dart`, run on macOS by discovery
  and on the Android emulator by `scripts/run_android_http_auth_tests.sh`.
- [ ] 4.2 Fork: send `previousFailureCount` from the WPE plugin as an integer
  (`isRetry ? 1 : 0`), bump the pinned ref, drop the Linux skip.

## 5. Localization

- [x] 5.1 Twelve keys in `app_en.arb`; the other 66 locales in their own commit.
