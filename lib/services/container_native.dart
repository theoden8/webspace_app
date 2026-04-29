import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/log_service.dart';

/// Cross-platform Dart-side bridge to the native per-site container API.
/// Maps each [WebViewModel.siteId] to a named native container
/// (`ws-<siteId>`) that owns its own cookies, localStorage, IndexedDB,
/// ServiceWorkers, and HTTP cache:
///
///   - Android (System WebView 110+, androidx.webkit 1.9+):
///     `androidx.webkit.Profile`.
///   - iOS 17+ / macOS 14+: `WKWebsiteDataStore(forIdentifier:)`.
///
/// All container lifecycle ops (delete, list) route through the
/// WebSpace fork's [`inapp.ContainerController`], which already
/// abstracts over both Apple and Android. The only shim that survives
/// app-side is a tiny Android MethodChannel for the
/// `WebViewFeature.MULTI_PROFILE` runtime feature gate — the fork
/// silently no-ops on unsupported devices, but the WebSpace engine
/// selection (this vs. [CookieIsolationEngine]) needs an explicit
/// yes/no, and the fork doesn't surface `MULTI_PROFILE` as a Dart
/// constant on `WebViewFeature`.
///
/// Binding a WebView to its container is done at construction via
/// [`inapp.InAppWebViewSettings.containerId`] (read by the fork's
/// `prepare()` / `preWKWebViewConfiguration` before any session-bound
/// op locks the WebView to the default store). There is no post-hoc
/// bind path — `bindContainerToWebView` is a no-op kept only so the
/// engine's interface stays uniform across the legacy and container
/// modes.
///
/// See [openspec/specs/per-site-containers/spec.md] for the per-platform
/// details and the legacy [CookieIsolationEngine] fallback used when
/// `isSupported()` returns false.
///
/// The interface is abstract so the engine ([ContainerIsolationEngine])
/// can be exercised headlessly with an in-memory mock that models
/// per-container partitioning, mirroring the [CookieIsolationEngine] +
/// `MockCookieManager` pattern in
/// [test/cookie_isolation_integration_test.dart].
abstract class ContainerNative {
  /// True iff the running platform + WebView combination supports
  /// per-site containers end to end.
  Future<bool> isSupported();

  /// Returns the canonical native name (`ws-<siteId>`). The container
  /// is materialized lazily on the native side when a WebView binds to
  /// it via [`inapp.InAppWebViewSettings.containerId`]; this method is
  /// pure-Dart and synchronous in practice.
  Future<String> getOrCreateContainer(String siteId);

  /// Returns 0. Bind happens at WebView construction via
  /// [`inapp.InAppWebViewSettings.containerId`]; there is no post-hoc
  /// bind path. Kept on the interface so the engine signature is
  /// uniform across legacy / container modes.
  Future<int> bindContainerToWebView(String siteId);

  /// Deletes the named container and all of its on-disk data
  /// (cookies, localStorage, IDB, SW, cache). The site's webview MUST
  /// be unloaded first — deleting an in-use container is a no-op /
  /// returns false on the native side.
  Future<void> deleteContainer(String siteId);

  /// Lists every site whose container currently exists in the native
  /// store. Result entries are bare siteIds (the `ws-` prefix is
  /// stripped). Used by orphan GC to detect containers whose owning
  /// site no longer exists.
  Future<List<String>> listContainers();

  /// Synchronous, cached copy of the most recent [isSupported] result.
  /// Defaults to `false` until the first async resolution completes.
  /// Call sites that need to branch *synchronously* during widget build
  /// (e.g. choosing whether to defer `initialUrlRequest` on the
  /// flutter_inappwebview construction path so the bind can win the
  /// race against `webView.loadUrl`) read this getter; the async
  /// resolution is performed once at startup in `_restoreAppState`.
  bool get cachedSupported;

  /// Default singleton routed to the platform-appropriate impl. Tests
  /// inject a mock directly into the engine instead.
  static final ContainerNative instance =
      (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)
          ? _ContainerNative()
          : _StubContainerNative();
}

/// Production impl. Lifecycle ops route through `inapp.ContainerController`
/// (the fork's cross-platform handle); `isSupported` does the
/// platform-appropriate runtime check.
class _ContainerNative implements ContainerNative {
  /// Channel used only on Android for the `WebViewFeature.MULTI_PROFILE`
  /// runtime gate. Backed by [`WebSpaceContainerPlugin.kt`].
  static const _androidProbe =
      MethodChannel('org.codeberg.theoden8.webspace/container');

  bool? _supportedCache;

  @override
  bool get cachedSupported => _supportedCache ?? false;

  @override
  Future<bool> isSupported() async {
    if (_supportedCache != null) return _supportedCache!;
    try {
      if (Platform.isAndroid) {
        final supported =
            await _androidProbe.invokeMethod<bool>('isSupported');
        _supportedCache = supported ?? false;
      } else if (Platform.isIOS || Platform.isMacOS) {
        // The fork's `isClassSupported` answers based on the build-time
        // platform; for iOS / macOS the underlying `WKWebsiteDataStore
        // (forIdentifier:)` API is `@available(iOS 17.0, macOS 14.0, *)`,
        // and the fork's plugin no-ops below that — but a pure
        // build-time check is enough here because iOS 17 / macOS 14 are
        // our runtime floor too (set in the project pbxproj). If the
        // floor changes, gate this behind an OS-version probe.
        _supportedCache = inapp.ContainerController.isClassSupported(
          platform: defaultTargetPlatform,
        );
      } else {
        _supportedCache = false;
      }
    } catch (e) {
      LogService.instance.log(
        'Container',
        'isSupported() failed: $e',
        level: LogLevel.error,
      );
      _supportedCache = false;
    }
    return _supportedCache!;
  }

  @override
  Future<String> getOrCreateContainer(String siteId) async => 'ws-$siteId';

  @override
  Future<int> bindContainerToWebView(String siteId) async => 0;

  @override
  Future<void> deleteContainer(String siteId) async {
    try {
      await inapp.ContainerController.instance()
          .deleteContainer('ws-$siteId');
    } catch (e) {
      LogService.instance.log(
        'Container',
        'deleteContainer($siteId) failed: $e',
        level: LogLevel.error,
      );
    }
  }

  @override
  Future<List<String>> listContainers() async {
    try {
      final names =
          await inapp.ContainerController.instance().getAllContainerNames();
      return [
        for (final name in names)
          if (name.startsWith('ws-')) name.substring(3),
      ];
    } catch (e) {
      LogService.instance.log(
        'Container',
        'listContainers() failed: $e',
        level: LogLevel.error,
      );
      return const [];
    }
  }
}

/// Fallback for unsupported platforms (Linux / Windows / web / future
/// targets). Returns `isSupported() == false`; engine selection in
/// [_WebSpacePageState] falls through to [CookieIsolationEngine] in
/// that case.
class _StubContainerNative implements ContainerNative {
  @override
  bool get cachedSupported => false;

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<String> getOrCreateContainer(String siteId) async => 'ws-$siteId';

  @override
  Future<int> bindContainerToWebView(String siteId) async => 0;

  @override
  Future<void> deleteContainer(String siteId) async {}

  @override
  Future<List<String>> listContainers() async => const [];
}
