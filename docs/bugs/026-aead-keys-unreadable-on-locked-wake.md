# BUG-026 — A background launch with the screen locked disables the encrypted caches

Status: **open.** Recorded before any fix; nothing below has shipped.

**Spec:** [web-push-notifications](../../openspec/specs/web-push-notifications/spec.md)
NOTIF-005-I (the wake that launches the app), [block-statistics](../../openspec/specs/block-statistics/spec.md)
STATS-009, [file-import-sites](../../openspec/specs/file-import-sites/spec.md),
[proxy-password-secure-storage](../../openspec/specs/proxy-password-secure-storage/spec.md)
(the `first_unlock` choice the credential stores already made)
**Code:** `Keystores.aeadKeys` in [lib/services/keystore.dart](../../lib/services/keystore.dart),
[lib/services/keychain_aead.dart](../../lib/services/keychain_aead.dart)
**Tests:** none yet. `test/secret_store_format_test.dart` pins each keystore's
options, so a fix that changes them must change that test on purpose.

## Symptom

On iOS, when a `BGAppRefreshTask` wake launches the process while the screen
is locked, for the rest of that process:

- the HTML cache neither reads nor writes (`HtmlCacheService`);
- imported pages show the fallback page (`HtmlImportStorage`);
- back/forward state is neither saved nor restored (`SecureWebViewStateStorage`);
- the protection report's itemised detail is not persisted
  (`SecureBlockStatsDetailStore`).

The data on disk is kept and comes back on the next launch made while the
device is unlocked. Nothing is lost; the stores are switched off.

## Root mechanism / invariant

The four AES keys these stores seal their files with live in the keychain
under `Keystores.aeadKeys`, which passes no `IOSOptions`, so the items carry
flutter_secure_storage's default accessibility, `unlocked`
(`kSecAttrAccessibleWhenUnlocked`). While the screen is locked,
`SecItemCopyMatching` answers `errSecInteractionNotAllowed`, which the plugin
reports as a `PlatformException`. `KeychainAead.open` reads that as "no key",
and each store keeps the failed open for the life of the process: the HTML
stores open once in `main()`, the webview state store marks itself
initialised, and the block-stats detail store memoises its first open.

The credential stores (`Keystores.credentials`) and the Tor bridge store
(`Keystores.torBridges`) chose `first_unlock` for this reason; the AEAD keys
and the archive slots (`Keystores.archive`) did not. An archive is only ever
opened by the user, so `unlocked` is right there.

The invariant: **a key a background wake can need is readable after first
unlock, or a failed open is retried once the device is unlocked, never kept
for the life of the process.**

## Fix attempts

1. **2026-10-07, #680.** *What:* the Tor bridge store, the one
   `first_unlock` store whose reader cached a failure, now answers a refused
   read with null (`TorBridgeSecureStorage.loadIfReadable`), and `TorEngine`
   stays un-hydrated on null so the next start asks again. Regression tests:
   "a refused read gives the engine nothing to keep (BUG-026)" and "a keystore
   that refuses leaves tor startable, and retries later". *Why:* the engine's
   retry path caught a throw the store never raises: `SecureJsonStore.read`
   turns a refusal into the default, bridges off, which the engine then kept
   for the process. *Why partial:* it covers the bridge store; the four AEAD
   stores above still keep a failed open.

## Known open gaps

- Changing the accessibility class is not an edit to `Keystores`: the class is
  part of the keychain query, so an item written under `unlocked` is not found
  under `first_unlock`. A fix reads the key under the old class, writes it
  under the new one and then deletes the old item.
- Retrying a failed open on the next use would restore the stores once the
  user unlocks, without touching the options. It would not make the cache
  usable during the wake itself.
- Android is not affected: the plugin ignores `encryptedSharedPreferences`
  and has no lock-state class.
