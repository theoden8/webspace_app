# `third_party/` — patched flutter_inappwebview plugins

WebSpace requires two per-site primitives that stock
`flutter_inappwebview` does not expose:

1. **Per-site cookie + storage isolation**:
   - **Android**: `androidx.webkit.Profile` (System WebView 110+).
     Bound via `WebViewCompat.setProfile(webView, profileName)`.
   - **iOS / macOS**: `WKWebsiteDataStore(forIdentifier: UUID)` (iOS
     17+ / macOS 14+). Set on `WKWebViewConfiguration.websiteDataStore`
     before `WKWebView(frame: configuration:)` runs.

2. **Per-site proxy** (iOS 17+ / macOS 14+ only):
   `WKWebsiteDataStore.proxyConfigurations`, attached to the per-site
   data store from item 1 inside the same `preWKWebViewConfiguration`
   block. This is the only Apple API that scopes a proxy to a single
   `WKWebView`. We deliberately diverge from upstream PR #2671 (which
   would route every view through the global `nonPersistent()` store
   and defeat per-site isolation); see
   [`openspec/specs/proxy/spec.md`](../openspec/specs/proxy/spec.md)
   PROXY-008 for the rationale and the Android asymmetry it documents.

Stock `flutter_inappwebview` does not expose either. Worse, both
platforms freeze the data-store decision before Dart can intercept:

- Android: `InAppWebView.prepare()` runs `addJavascriptInterface`,
  `addDocumentStartJavaScript`, and
  `CookieManager.setAcceptThirdPartyCookies(this, ...)` synchronously
  inside `FlutterWebViewFactory.create()`, before `onWebViewCreated`
  fires Dart-side. Each one locks the WebView to whichever profile
  is current — there's no way to re-bind from Dart afterwards.
- iOS / macOS: `WKWebViewConfiguration.websiteDataStore` is copied
  at `WKWebView.init` and frozen — no `setWebsiteDataStore(_:)` on a
  live view. The bind has to happen during
  `preWKWebViewConfiguration(settings:)`, before the configuration
  reaches `WKWebView.init`.

So we patch the plugins. The patches are tiny (~5 sites across 3
plugins), self-contained, and marked with `// [WebSpace fork patch]`
comments. Every patched line can be located by:

```sh
grep -rn '\[WebSpace fork patch\]' .dart_tool/webspace_patched_plugins/
```

(or against the `.patch` files in this directory, which is what
review will see).

## How it's wired

We do **not** vendor the plugin source into the repo. Instead:

1. The diffs against the upstream pub.dev tarballs live as
   `.patch` files in this directory:

   - `flutter_inappwebview_android.patch` — pinned to upstream 1.2.0-beta.3
   - `flutter_inappwebview_ios.patch`     — pinned to upstream 1.2.0-beta.3
   - `flutter_inappwebview_macos.patch`   — pinned to upstream 1.2.0-beta.3
   - `flutter_inappwebview_linux.patch`   — pinned to upstream 0.1.0-beta.1
     (per-site profile binding via `webkit_network_session_new(dataDir,
     cacheDir)`. See cheat-sheet below. Drop when upstream adds a
     native `webspaceProfile` setting.)

   Pinning lives in
   [`scripts/apply_plugin_patches.dart`](../scripts/apply_plugin_patches.dart),
   not in `pubspec.yaml`.

2. [`scripts/apply_plugin_patches.dart`](../scripts/apply_plugin_patches.dart)
   copies the upstream tarball from `~/.pub-cache/hosted/pub.dev/<plugin>-<version>/`
   into `.dart_tool/webspace_patched_plugins/<plugin>/` and runs
   `patch -p1 --input third_party/<plugin>.patch` against that copy.

3. [`pubspec.yaml`](../pubspec.yaml)'s `dependency_overrides` point
   each plugin at the corresponding `.dart_tool/webspace_patched_plugins/<plugin>/`
   path.

`.dart_tool/` is gitignored, so the patched copies never leak into
the repo. CI regenerates them on every build.

## Workflow

### Clean checkout / fresh CI runner

One command:

```sh
dart run scripts/apply_plugin_patches.dart
```

The script:

1. Materializes patched copies of the three plugins under
   `.dart_tool/webspace_patched_plugins/<plugin>/`. If
   `~/.pub-cache/` lacks an upstream version we expect, it downloads
   the tarball from `https://pub.dev/api/archives/<plugin>-<version>.tar.gz`
   and extracts it there. This sidesteps the chicken-and-egg of
   running `flutter pub get` first — pub validates that
   `dependency_overrides` paths exist *before* downloading anything,
   so a plain `flutter pub get` on a fresh checkout fails with exit
   66 ("could not find package flutter_inappwebview_macos at
   .dart_tool/…").
2. Runs `flutter pub get --enforce-lockfile` for you against the
   now-existing override paths.

CI runs the same single command; see
[`.github/workflows/build-and-test.yml`](../.github/workflows/build-and-test.yml).

### Routine development

After that one-shot, plain `flutter pub get` works. Re-run the
script only if the upstream version pin in
`scripts/apply_plugin_patches.dart` or a `.patch` file changes.

### Upgrading to a newer upstream

When `flutter_inappwebview` (or one of its platform packages) ships
a new release:

1. Bump the corresponding entry in `_plugins` in
   `scripts/apply_plugin_patches.dart` to the new upstream version.

2. `flutter pub get` to fetch it into the pub-cache.

3. Try the script: `dart run scripts/apply_plugin_patches.dart`.

   - If it succeeds, you're done — upstream didn't move the lines we
     touch.
   - If `patch` fails, upstream moved a line our patch touches.
     Resolve manually:
     ```sh
     # Re-apply with rejection files for the failing hunks.
     cd .dart_tool/webspace_patched_plugins/<plugin>
     patch -p1 --input ../../../third_party/<plugin>.patch \
       --merge --backup --suffix .orig
     # Edit the .rej or .orig files to fix the hunks, then regenerate
     # the patch:
     diff -urN \
       ~/.pub-cache/hosted/pub.dev/<plugin>-<new-version> \
       .dart_tool/webspace_patched_plugins/<plugin> \
       > ../../../third_party/<plugin>.patch
     ```

4. Run the test suite:
   ```sh
   flutter analyze
   flutter test
   flutter build apk --flavor fdroid --release
   ```

5. Manual smoke test: two same-base-domain sites loaded
   simultaneously must have isolated sessions. On Android, look for
   the absence of `WebSpace fork: setProfile(...) failed` in
   `adb logcat -s InAppWebView`.

### Removing the fork (if upstream merges native profile support)

If `pichillilorenzo/flutter_inappwebview` ever exposes a first-class
per-site profile API:

1. Update [`lib/services/webview.dart`](../lib/services/webview.dart)
   to use the upstream-named setting in plain
   `inapp.InAppWebViewSettings` and drop
   `WebSpaceInAppWebViewSettings`.
2. Drop the `dependency_overrides` entries from `pubspec.yaml`.
3. Delete `third_party/flutter_inappwebview_*.patch`,
   `scripts/apply_plugin_patches.dart`, and the corresponding CI
   steps in `.github/workflows/build-and-test.yml`.
4. Update [`openspec/specs/per-site-profiles/spec.md`](../openspec/specs/per-site-profiles/spec.md)
   PROF-005 to reference the upstream API.

## Patch contents (cheat-sheet)

Each patch touches the minimum needed:

- a new `webspaceProfile` field on the plugin's settings type,
- the bind block at the construction-time injection point,
- (iOS / macOS) a `webspaceProxy` field on the same settings type +
  a sibling block in `preWKWebViewConfiguration` that sets
  `proxyConfigurations` on the per-site data store, +
  a `WebSpaceProxy.swift` helper that builds
  `[Network.ProxyConfiguration]` from the dict,
- (iOS / macOS) a `WebSpaceProfile.swift` helper that derives a
  deterministic UUID from the profile name via SHA-256 — Apple's
  `WKWebsiteDataStore(forIdentifier:)` requires a UUID and our siteIds
  are opaque strings,
- (iOS / macOS) `MyCookieManager` is rerouted to look up the WebView's
  per-site `WKHTTPCookieStore` via `webViewId` so DevTools cookie ops
  hit the bound profile instead of the default jar.

| Plugin | Files touched | Total LOC added |
|---|---|---|
| flutter_inappwebview_android | InAppWebView.java, InAppWebViewSettings.java | ~25 |
| flutter_inappwebview_ios     | InAppWebView.swift, InAppWebViewSettings.swift, WebSpaceProfile.swift (new), WebSpaceProxy.swift (new), MyCookieManager.swift, lib/src/cookie_manager.dart | ~140 |
| flutter_inappwebview_macos   | InAppWebView.swift, InAppWebViewSettings.swift, WebSpaceProfile.swift (new), WebSpaceProxy.swift (new), MyCookieManager.swift, lib/src/cookie_manager.dart | ~140 |
| flutter_inappwebview_linux   | linux/in_app_webview/in_app_webview.cc, in_app_webview_settings.{h,cc} | ~60 |

The Linux patch adds a `webspaceProfile: String` field to
`InAppWebViewSettings` and, when non-empty AND not in incognito mode,
swaps the default shared `WebKitNetworkSession` for
`webkit_network_session_new(dataDir, cacheDir)` at WebView
construction. Each `webspaceProfile` value (`ws-<siteId>` from the
Dart engine layer) maps to a fixed XDG directory pair under
`$XDG_DATA_HOME/webspace/profiles/<name>/data` and
`$XDG_CACHE_HOME/webspace/profiles/<name>/cache`. The runner-side
`linux/web_space_profile_plugin.cc` handles the lifecycle channel
(create/delete/list) using the same path convention — keep them in
sync if the convention ever changes.

The patch covers BOTH WPE backend variants the upstream plugin
supports: the modern `HAVE_WPE_PLATFORM` branch (~line 670) and the
legacy `HAVE_WPE_BACKEND_LEGACY` branch (~line 832, nested in an
`else` block — note the four-space indentation).

Stock upstream's main-frame detection in `decide-policy` uses a
frame-name heuristic that misclassifies unnamed iframe navigations.
The natural fix would be
`webkit_navigation_action_is_for_main_frame(nav_action)`, but that
function doesn't exist in WebKit's public C API (verified against
`Source/WebKit/UIProcess/API/glib/WebKitNavigationAction.cpp` on
WebKit `main`). We accept the misclassification because once
per-site profiles bind, every webview gets its own jar regardless of
which frame is navigating — iframes inherit the parent webview's
profile by design, which is the correct behavior. Revisit only if
upstream WebKit eventually exposes a source-frame accessor.

Specs:
- [`openspec/specs/per-site-profiles/spec.md`](../openspec/specs/per-site-profiles/spec.md)
- [`openspec/specs/proxy/spec.md`](../openspec/specs/proxy/spec.md) (PROXY-008 covers the Android↔iOS asymmetry)

License: upstream is Apache 2.0; our patches are also Apache 2.0.
