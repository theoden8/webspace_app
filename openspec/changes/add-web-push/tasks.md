# Tasks

## 1. Gate and dependency

- [ ] 1.1 Pin `org.unifiedpush.android:connector` (AND_3, 3.x) in `android/app/build.gradle`, confirm its licence fits the F-Droid build (`legal` spec) and record the exact register, unregister, distributor and `PushService` API in design.md's Context; verify `gradle :app:testFdroidDebugUnitTest` compiles
- [ ] 1.2 Add the Web Push `AppPref` and its `ExperimentalFeature`, offered only on Android (WEBPUSH-001, DEVTOOLS-011); verify `fvm flutter test test/settings_backup_test.dart` passes (the pref rides `AppPref.values`)
- [ ] 1.3 Add the Experimental group's row and a widget test that it shows on Android only; test names cite WEBPUSH-001

## 2. Keys and decryption

- [ ] 2.1 Add the RFC 8291 `aes128gcm` decryption engine in `lib/services/` (design Decision 2) and its test over RFC 8291's worked example, with planted mistakes (a wrong auth secret, a truncated record, the old `aesgcm` encoding) that must each fail; test names cite WEBPUSH-005
- [ ] 2.2 Add the per-site push store (`SecureJsonStore` on `Keystores.credentials`: token, keys, endpoint, granted origin) and its `OrphanStore` entry; verify `fvm flutter analyze` is clean (the sweep's exhaustive switch) and the orphan sweep test passes
- [ ] 2.3 Add a backup and QR test that an allowed site's endpoint, keys and grant appear in neither (WEBPUSH-008)

## 3. Permission

- [ ] 3.1 Add the permission engine and its sealed answer (design Decision 6) with a table test over offered, on screen, prompt up, grant, grant origin and current origin; test names cite WEBPUSH-002, WEBPUSH-003
- [ ] 3.2 Add the prompt (`Dialog*Prompts`), defaulting to no, with the site, the distributor, the push server host, the two disclosures and the proxied or Tor line first where it applies; strings in `lib/l10n/app_en.arb`, translations in their own commit; a widget test that dismissing refuses (WEBPUSH-003)
- [ ] 3.3 Add the site's notification row (the push server it was allowed for, Revoke) and App Settings' Push distributor row (installed distributors, the one picked, none installed); a widget test each (WEBPUSH-001, WEBPUSH-007)

## 4. Native bridge

- [ ] 4.1 Add the Kotlin plugin over the connector: register an instance per opaque token with the site's VAPID key, unregister, list and pick distributors, report endpoints; register it in `EnginePlugins` so the worker engine has it (design Decision 1)
- [ ] 4.2 Declare the connector's `PushService` and a dispatcher that hands messages to the bound engine or starts `WorkerFlutterEngine`, queueing and delivering one at a time (design Decision 5); a JVM test of the dispatcher's queue and its engine-gone release
- [ ] 4.3 Extend `test/js/background_wake_cold_engine.test.js` (or a sibling gate) so a push that finds no engine starts one and stops it after (WEBPUSH-006); extend `notification_no_foreground_service.test.js` to cover the push service (NOTIF-015)

## 5. Page script

- [ ] 5.1 Add `PushManager`, `pushManager`, `PushSubscription` to `lib/js/notification_polyfill.js`, configured through `withConfig` (offered, state); record each subscription's scope and `active.scriptURL`; jsdom tests of the API's shape, `subscribe()` without a key, and an incognito or archive site seeing none (WEBPUSH-002)
- [ ] 5.2 Add the delivery worker's prelude as a `lib/js/` part (design Decision 3) and jsdom tests that a sample service worker's `push` handler runs, its `showNotification` reaches the bridge, and one that shows nothing or throws ends in the notice (WEBPUSH-005)
- [ ] 5.3 Add a browser-tier test (`test/browser/`) running the prelude in real Chromium against a service worker script that reads IndexedDB before showing its notification

## 6. Delivery

- [ ] 6.1 Add the push input to `BackgroundWakeEngine.table` (design Decision 4): a plan of one site, its middle handing the payload to the page; engine tests that a live site delivers in place, an unloaded one headless, and a skip ends in the notice (WEBPUSH-005, WEBPUSH-006)
- [ ] 6.2 Print the new input into `activation.tla`, add a world and a planted mistake for it, and run `./formal/verify.sh` and `trace/check_steps.sh`; name the base config's `Finished in` before and after in the PR
- [ ] 6.3 Revoke on each WEBPUSH-007 trigger (the row, notifications off, delete, the switch off, another distributor) through one funnel; a test per trigger that the registration and keys are gone

## 7. End to end

- [ ] 7.1 Add an emulator scenario to `scripts/run_android_lifecycle_tests.sh` with a test distributor: subscribe from a fixture page, kill the app process, push from the host with a Web Push library, and require the service worker's notification (WEBPUSH-006)
- [ ] 7.2 Drop each new requirement's row from `openspec/unverified.tsv` as its check lands; verify `node --test test/js/spec_verification.test.js` passes
