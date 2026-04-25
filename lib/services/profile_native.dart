import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// Cross-platform Dart-side bridge to the native Profile API. On Android
/// (System WebView 110+, androidx.webkit 1.9+) maps each `WebViewModel.siteId`
/// to a named native profile (`ws-<siteId>`) that owns its own cookies,
/// localStorage, IndexedDB, ServiceWorkers, and HTTP cache. On iOS / macOS
/// this currently returns `isSupported() == false` — see
/// [openspec/specs/per-site-profiles/spec.md] for why and the path forward.
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

  /// Default singleton routed to the platform-appropriate impl. Tests
  /// inject a mock directly into the engine instead.
  static final ProfileNative instance =
      Platform.isAndroid ? _MethodChannelProfileNative() : _StubProfileNative();
}

class _MethodChannelProfileNative implements ProfileNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/profile');

  bool? _supportedCache;

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

/// iOS / macOS / Linux / desktop: Profile API not yet wired (the Apple
/// equivalent `WKWebsiteDataStore(forIdentifier:)` exists since iOS 17 but
/// flutter_inappwebview does not yet expose `websiteDataStoreId` on
/// `InAppWebViewSettings`). Returns `isSupported() == false`; engine
/// selection in [_WebSpacePageState] then falls through to
/// [CookieIsolationEngine].
class _StubProfileNative implements ProfileNative {
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
