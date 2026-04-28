# `third_party/` — patched flutter_inappwebview plugins

WebSpace requires per-site cookie + storage isolation. The native
primitives are:

- **Android**: `androidx.webkit.Profile` (System WebView 110+).
  Bound via `WebViewCompat.setProfile(webView, profileName)`.
- **iOS / macOS**: `WKWebsiteDataStore(forIdentifier: UUID)` (iOS
  17+ / macOS 14+). Set on `WKWebViewConfiguration.websiteDataStore`
  before `WKWebView(frame: configuration:)` runs.

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

   - `flutter_inappwebview_android.patch` — pinned to upstream 1.1.3
   - `flutter_inappwebview_ios.patch`     — pinned to upstream 1.1.2
   - `flutter_inappwebview_macos.patch`   — pinned to upstream 1.1.2

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

Each patch touches the minimum needed: a new `webspaceProfile` field
on the plugin's settings type, the bind block at the
construction-time injection point, and (on iOS / macOS) a small
`WebSpaceProfile.swift` helper that derives a deterministic UUID
from the profile name via SHA-256 — Apple's
`WKWebsiteDataStore(forIdentifier:)` requires a UUID and our siteIds
are opaque strings.

| Plugin | Files touched | Total LOC added |
|---|---|---|
| flutter_inappwebview_android | InAppWebView.java, InAppWebViewSettings.java | ~25 |
| flutter_inappwebview_ios     | InAppWebView.swift, InAppWebViewSettings.swift, WebSpaceProfile.swift (new) | ~30 |
| flutter_inappwebview_macos   | InAppWebView.swift, InAppWebViewSettings.swift, WebSpaceProfile.swift (new) | ~30 |

Spec: [`openspec/specs/per-site-profiles/spec.md`](../openspec/specs/per-site-profiles/spec.md).

License: upstream is Apache 2.0; our patches are also Apache 2.0.
