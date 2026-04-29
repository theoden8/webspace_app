import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// Cross-platform Dart-side bridge to the native Profile API. Maps each
/// [WebViewModel.siteId] to a named native profile (`ws-<siteId>`) that
/// owns its own cookies, localStorage, IndexedDB, ServiceWorkers, and
/// HTTP cache:
///
///   - Android (System WebView 110+, androidx.webkit 1.9+):
///     `androidx.webkit.Profile`.
///   - iOS 17+ / macOS 14+: `WKWebsiteDataStore(forIdentifier:)`.
///   - Linux (libwpewebkit-2.0 ≥ 2.40): `WebKitNetworkSession` with
///     persistent dataDirectory + cacheDirectory, scoped under
///     `$XDG_DATA_HOME/webspace/profiles/ws-<siteId>/{data,cache}`.
///
/// See [openspec/specs/per-site-profiles/spec.md] for the per-platform
/// details and the legacy [CookieIsolationEngine] fallback used when
/// `isSupported()` returns false.
///
/// The interface is abstract so the engine ([ProfileIsolationEngine]) can
/// be exercised headlessly with an in-memory mock that models per-profile
/// partitioning, mirroring the [CookieIsolationEngine] +
/// `MockCookieManager` pattern in
/// [test/cookie_isolation_integration_test.dart].
abstract class ProfileNative {
  /// True iff the running platform + WebView combination supports
  /// per-site profiles end to end.
  Future<bool> isSupported();

  /// Idempotent: ensures the named profile for [siteId] exists in the
  /// native ProfileStore and returns the canonical native name
  /// (`ws-<siteId>`).
  Future<String> getOrCreateProfile(String siteId);

  /// Walks the activity's view tree and binds every flutter_inappwebview
  /// WebView created for [siteId] to the matching profile. Returns the
  /// number of webviews bound. No-op on platforms where
  /// [isSupported] is false.
  Future<int> bindProfileToWebView(String siteId);

  /// Deletes the named profile and all of its on-disk data (cookies,
  /// localStorage, IDB, SW, cache). The site's webview MUST be unloaded
  /// first — deleting an in-use profile throws on Android.
  Future<void> deleteProfile(String siteId);

  /// Lists every site whose profile currently exists in ProfileStore.
  /// Result entries are bare siteIds (the `ws-` prefix is stripped on
  /// the native side). Used by orphan GC to detect profiles whose owning
  /// site no longer exists.
  Future<List<String>> listProfiles();

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
  ///
  /// Android, iOS / macOS, and Linux all take the MethodChannel path:
  /// the vendored forks under `third_party/` patch each plugin's
  /// WebView construction to set the per-site profile / data store
  /// before any session-bound op. The native side answers
  /// `isSupported()` based on a runtime check:
  ///   - Android: `WebViewFeature.MULTI_PROFILE`
  ///   - iOS / macOS: `#available(iOS 17.0, macOS 14.0, *)`
  ///   - Linux: always TRUE — the patched plugin links against
  ///     libwpewebkit-2.0 ≥ 2.40 (`WebKitNetworkSession` API), which
  ///     `pkg_check_modules` enforces at compile time.
  /// Engine selection in `_WebSpacePageState` falls through to
  /// `CookieIsolationEngine` when `isSupported()` returns false.
  static final ProfileNative instance = (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux)
      ? _MethodChannelProfileNative()
      : _StubProfileNative();
}

class _MethodChannelProfileNative implements ProfileNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/profile');

  bool? _supportedCache;

  @override
  bool get cachedSupported => _supportedCache ?? false;

  @override
  Future<bool> isSupported() async {
    if (_supportedCache != null) return _supportedCache!;
    try {
      final supported = await _channel.invokeMethod<bool>('isSupported');
      _supportedCache = supported ?? false;
    } catch (e) {
      LogService.instance.log(
        'Profile',
        'isSupported() native call failed: $e',
        level: LogLevel.error,
      );
      _supportedCache = false;
    }
    return _supportedCache!;
  }

  @override
  Future<String> getOrCreateProfile(String siteId) async {
    final name = await _channel
        .invokeMethod<String>('getOrCreateProfile', {'siteId': siteId});
    return name ?? 'ws-$siteId';
  }

  @override
  Future<int> bindProfileToWebView(String siteId) async {
    try {
      final count = await _channel
          .invokeMethod<int>('bindProfileToWebView', {'siteId': siteId});
      return count ?? 0;
    } catch (e) {
      LogService.instance.log(
        'Profile',
        'bindProfileToWebView($siteId) failed: $e',
        level: LogLevel.error,
      );
      return 0;
    }
  }

  @override
  Future<void> deleteProfile(String siteId) async {
    try {
      await _channel.invokeMethod<void>('deleteProfile', {'siteId': siteId});
    } catch (e) {
      LogService.instance.log(
        'Profile',
        'deleteProfile($siteId) failed: $e',
        level: LogLevel.error,
      );
    }
  }

  @override
  Future<List<String>> listProfiles() async {
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('listProfiles');
      if (list == null) return const [];
      return list.cast<String>();
    } catch (e) {
      LogService.instance.log(
        'Profile',
        'listProfiles() failed: $e',
        level: LogLevel.error,
      );
      return const [];
    }
  }
}

/// Fallback for unsupported platforms (Windows / web / future targets).
/// Returns `isSupported() == false`; engine selection in
/// [_WebSpacePageState] falls through to [CookieIsolationEngine] in
/// that case. Android / iOS / macOS / Linux all use
/// [_MethodChannelProfileNative].
class _StubProfileNative implements ProfileNative {
  @override
  bool get cachedSupported => false;

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<String> getOrCreateProfile(String siteId) async => 'ws-$siteId';

  @override
  Future<int> bindProfileToWebView(String siteId) async => 0;

  @override
  Future<void> deleteProfile(String siteId) async {}

  @override
  Future<List<String>> listProfiles() async => const [];
}
