import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/keychain_aead.dart';
import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/utils/concurrency.dart';

/// AES-encrypted, on-disk implementation of [WebViewStateStorage]: each
/// state blob sealed by [KeychainAead] and written to
/// `<docs>/webview_state/<siteId>.<tabId>.enc`.
///
/// State survives cold starts. On app upgrade the cache directory is
/// nuked and the key rotated alongside it: a back/forward stack from a
/// previous app version is unlikely to re-hydrate cleanly anyway.
///
/// On disk rather than straight in the keystore: `saveState()` returns
/// 1-50 KB that grows with deep history, and an iOS Keychain item is capped
/// at ~4 KB. The keychain holds only the 32-byte key.
class SecureWebViewStateStorage implements WebViewStateStorage {
  static const String _versionKey = 'webview_state_cache_version';
  static const String _cacheDir = 'webview_state';
  static const String _encryptionKeyKey = 'webview_state_encryption_key';

  final FlutterSecureStorage _secureStorage;
  /// Optional override for the cache parent directory. When null,
  /// `getApplicationDocumentsDirectory()` is queried at init. Tests
  /// inject a temp dir to avoid the path_provider plugin.
  final FileStore? _overrideStore;
  /// Optional override for the version-tracking SharedPreferences-
  /// equivalent. When null, [SharedPreferences] is queried.
  /// Tests inject a stub to avoid plugin setup.
  final String Function()? _versionProvider;

  FileStore? _store;
  KeychainAead? _aead;
  bool _initialized = false;
  final SingleFlight<(), void> _init = SingleFlight();

  SecureWebViewStateStorage({
    FlutterSecureStorage? secureStorage,
    FileStore? store,
    String Function()? versionProvider,
  })  : _secureStorage = secureStorage ?? Keystores.aeadKeys,
        _overrideStore = store,
        _versionProvider = versionProvider;

  /// Idempotent. Must complete before any save/load — the AES key is
  /// provisioned here (or rotated on app upgrade) and the cache directory is
  /// created if missing.
  Future<void> initialize() {
    if (_initialized) return Future.value();
    // Shared so two first-touch callers (a first loadState racing a first
    // saveState) cannot each generate and persist a different key.
    return _init.run((), call: _doInitialize);
  }

  Future<void> _doInitialize() async {
    try {
      _store = _overrideStore ?? defaultFileStore(_cacheDir);
      _aead = await KeychainAead.open(_secureStorage,
          keyName: _encryptionKeyKey, logTag: LogTag.webViewState);
      await _clearCacheOnUpgrade();
      await _store!.ensure();
      _initialized = true;
    } on Exception catch (e) {
      // Never let an init failure escape: callers `await initialize()` from
      // inside save/load, which run on the go-home and site-switch paths —
      // a throw there used to abandon the navigation the user asked for.
      // Nothing is initialized, so save/load degrade to no-ops below.
      LogTag.webViewState.error('Error initializing state storage: $e');
    }
  }

  Future<void> _clearCacheOnUpgrade() async {
    final String currentVersion;
    final String? lastVersion;
    final SharedPreferences? prefs;
    if (_versionProvider != null) {
      currentVersion = _versionProvider();
      // Test path: persist version via the injected secure storage so
      // the next instance with a different versionProvider triggers
      // rotation. Returns null on first run, just like the production
      // SharedPreferences path.
      prefs = null;
      lastVersion = await _secureStorage.read(key: '$_versionKey.test');
    } else {
      prefs = await SharedPreferences.getInstance();
      final info = await PackageInfo.fromPlatform();
      currentVersion = '${info.version}+${info.buildNumber}';
      lastVersion = prefs.getString(_versionKey);
    }
    if (lastVersion != currentVersion) {
      if (lastVersion != null && _store != null) {
        try {
          await _store!.deleteAll();
        } on Exception catch (e) {
          LogTag.webViewState.error('Error clearing cache on upgrade: $e');
        }
        _aead = await KeychainAead.rotate(_secureStorage,
            keyName: _encryptionKeyKey, logTag: LogTag.webViewState);
      }
      if (prefs != null) {
        await prefs.setString(_versionKey, currentVersion);
      } else {
        await _secureStorage.write(
          key: '$_versionKey.test',
          value: currentVersion,
        );
      }
    }
  }

  String _fileNameFor(String key) => '$key.enc';

  /// Strip the extension by length, not by [String.replaceAll]: a state key
  /// contains a `.` of its own, and a tab an imported backup named `enc`
  /// would otherwise have its whole name eaten.
  String _keyForFileName(String name) =>
      name.substring(0, name.length - '.enc'.length);

  @override
  Future<void> saveState(String key, {required Uint8List state}) async {
    if (state.isEmpty) return;
    if (!_initialized) await initialize();
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return;
    try {
      await store.writeText(_fileNameFor(key),
          contents: aead.seal(base64.encode(state)));
      LogTag.webViewState.debug(
          'Saved ${state.length} bytes for $key (encrypted)', sensitive: true);
    } on Exception catch (e) {
      LogTag.webViewState.error(
          'Error saving state for $key: $e', sensitive: true);
    }
  }

  @override
  Future<Uint8List?> loadState(String key) async {
    if (!_initialized) await initialize();
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return null;
    final String? raw;
    try {
      raw = await store.readText(_fileNameFor(key));
    } on Exception catch (e) {
      LogTag.webViewState.error(
          'Error loading state for $key: $e', sensitive: true);
      return null;
    }
    if (raw == null) return null;
    final opened = aead.unseal(raw);
    final bytes = opened == null ? null : _decodeBase64(opened);
    if (bytes != null) return bytes;
    LogTag.webViewState.error(
        'Discarding unreadable state for $key', sensitive: true);
    // Removed so a re-save can succeed and a load does not keep failing.
    try {
      await store.delete(_fileNameFor(key));
    } on Exception catch (e) {
      LogTag.webViewState.warning('Could not discard it: $e', sensitive: true);
    }
    return null;
  }

  static Uint8List? _decodeBase64(String text) {
    try {
      return base64.decode(text);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> removeState(String key) async {
    if (!_initialized) await initialize();
    final store = _store;
    if (store == null) return;
    try {
      await store.delete(_fileNameFor(key));
    } on Exception catch (e) {
      LogTag.webViewState.error(
          'Error deleting state for $key: $e', sensitive: true);
    }
  }

  @override
  Future<int> removeStatesForSite(String siteId) async {
    if (!_initialized) await initialize();
    final store = _store;
    if (store == null) return 0;
    final prefix = '$siteId.';
    var removed = 0;
    try {
      for (final name in await store.list()) {
        if (!name.endsWith('.enc')) continue;
        if (!_keyForFileName(name).startsWith(prefix)) continue;
        await store.delete(name);
        removed++;
      }
    } on Exception catch (e) {
      LogTag.webViewState.error('Error removing state files for a site: $e');
    }
    return removed;
  }

  @override
  Future<int> removeOrphans(Set<String> activeKeys) async {
    if (!_initialized) await initialize();
    final store = _store;
    if (store == null) {
      return 0;
    }
    var removed = 0;
    try {
      final entries = await store.list();
      for (final name in entries) {
        if (!name.endsWith('.enc')) continue;
        if (!activeKeys.contains(_keyForFileName(name))) {
          await store.delete(name);
          removed++;
        }
      }
      if (removed > 0) {
        LogTag.webViewState.debug('Removed $removed orphan state file(s)');
      }
    } on Exception catch (e) {
      LogTag.webViewState.error('Error sweeping orphan state files: $e');
    }
    return removed;
  }

  @override
  Future<Set<String>> siteIds() async {
    if (!_initialized) await initialize();
    final store = _store;
    if (store == null) {
      return const <String>{};
    }
    final result = <String>{};
    try {
      final entries = await store.list();
      for (final name in entries) {
        if (!name.endsWith('.enc')) continue;
        result.add(_keyForFileName(name));
      }
    } on Exception catch (e) {
      LogTag.webViewState.warning('Could not list state files: $e');
    }
    return result;
  }
}
