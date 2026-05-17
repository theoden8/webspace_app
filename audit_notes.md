# Native-side log audit

Scope: in-repo native code only. Upstream flutter_inappwebview fork logs are enumerated at the bottom but NOT patched here.

## Android (`android/app/src/main/kotlin/`)

All native Log calls live in `AdblockEngineNative.kt` and report only engine state (load probe, build, dispose, teardown). None include per-site identifiers, container names, cookie hostnames, URLs, page titles, or proxy credentials. Left as-is.

- `AdblockEngineNative.kt:47` `Log.i(TAG, "webspace_adblock JNI loaded")`
- `AdblockEngineNative.kt:49` `Log.w(TAG, "webspace_adblock loaded but probe returned false")`
- `AdblockEngineNative.kt:55` `Log.i(TAG, "webspace_adblock JNI not loaded: ${t.message}")` — JNI load error, no site data.
- `AdblockEngineNative.kt:81` `Log.i(TAG, "engine torn down")`
- `AdblockEngineNative.kt:86` `Log.i(TAG, "engine built (...)")` — rule-byte count only.
- `AdblockEngineNative.kt:128` `Log.i(TAG, "engine disposed")`

## iOS (`ios/Runner/`)

`AppDelegate.swift` had 8 `NSLog` calls that printed inbound share URLs verbatim to the iOS console. Each one is now wrapped in `#if DEBUG / #endif` so release builds compile them out. The signals are useful while developing the share-extension path but must not reach a shipped app's `os_log` stream.

Other native NSLog callers reviewed and left alone (no per-site data):

- `ShortcutsPlugin.swift:77` — App Group unavailable warning; static config.
- `BackgroundTaskPlugin.swift:99` — `BGAppRefreshTask` schedule error; iOS error message only.
- `WebSpaceAppIntents.swift:94` — App Group unavailable warning; static config.

## Linux (`linux/`)

`my_application.cc` has two `g_warning` calls; both are generic GLib/Flutter response/registration errors with no per-site data. Left as-is.

- `my_application.cc:62` `g_warning("Failed to send share-intent response: %s", error->message);`
- `my_application.cc:158` `g_warning("Failed to register: %s", error->message);`

## Upstream fork (`~/.pub-cache/git/flutter_inappwebview-*/`)

Not patched per instructions. There are ~89 `Log.*` / `NSLog` / `os_log` calls across the fork's plugin packages (Android, iOS, macOS, Linux). Most are upstream library code that predates our fork patches; common sites:

- `flutter_inappwebview_android/.../MyCookieManager.java` — generic error logs (no cookie host).
- `flutter_inappwebview_android/.../Util.java` — error helper.
- `flutter_inappwebview_android/.../InAppBrowserActivity.java` — file/menu errors.
- Many platform plugins log error stack traces only.

A pass to silence these on release builds upstream would be welcome but is out of scope for this branch.

Reproduce with:

```sh
grep -rn 'Log\.d\|Log\.i\|Log\.w\|Log\.e\|Log\.v\|NSLog\|os_log' ~/.pub-cache/git/flutter_inappwebview-*/
```
