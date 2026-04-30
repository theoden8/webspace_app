import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview_state_storage.dart';

/// AES-encrypted, on-disk implementation of [WebViewStateStorage].
///
/// Models the [HtmlCacheService] pattern: a 256-bit AES-CBC key lives
/// in [FlutterSecureStorage] (platform keychain / keystore), the
/// per-site state bytes are encrypted with a fixed IV derived from
/// that key and written to `<docs>/webview_state/<siteId>.enc`.
///
/// State survives cold starts. On app upgrade the cache directory is
/// nuked (key is rotated alongside it) — the back/forward stack from
/// a previous app version is unlikely to re-hydrate cleanly anyway.
///
/// Why on-disk instead of straight `flutter_secure_storage`:
/// `saveState()` returns a `Uint8List` that's typically 1-50 KB but
/// can grow with deep history. iOS Keychain caps individual items at
/// ~4 KB, and Android EncryptedSharedPreferences degrades with size.
/// AES-on-disk handles arbitrary sizes; the keychain only holds the
/// 32-byte AES key.
///
/// File format: base64(AES-CBC(state-bytes)). Reads decrypt to
/// `Uint8List`; the IV is fixed (per-key) so identical bytes encrypt
/// to identical ciphertext — fine, the threat model is "device
/// compromise" not "ciphertext analysis", and matches the HTML cache
/// shape so future contributors don't have to learn two patterns.
class SecureWebViewStateStorage implements WebViewStateStorage {
  static const String _versionKey = 'webview_state_cache_version';
  static const String _cacheDir = 'webview_state';
  static const String _encryptionKeyKey = 'webview_state_encryption_key';

  final FlutterSecureStorage _secureStorage;
  /// Optional override for the cache parent directory. When null,
  /// `getApplicationDocumentsDirectory()` is queried at init. Tests
  /// inject a temp dir to avoid the path_provider plugin.
  final Directory? _overrideAppDir;
  /// Optional override for the version-tracking SharedPreferences-
  /// equivalent. When null, [SharedPreferences] is queried.
  /// Tests inject a stub to avoid plugin setup.
  final String Function()? _versionProvider;

  Directory? _cacheDirectory;
  encrypt.Encrypter? _encrypter;
  encrypt.IV? _iv;
  bool _initialized = false;

  SecureWebViewStateStorage({
    FlutterSecureStorage? secureStorage,
    Directory? overrideAppDir,
    String Function()? versionProvider,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _overrideAppDir = overrideAppDir,
        _versionProvider = versionProvider;

  /// Initialize the storage. Idempotent. Must complete before any
  /// save/load — the AES key is provisioned here (or rotated on app
  /// upgrade) and the cache directory is created if missing.
  Future<void> initialize() async {
    if (_initialized) return;
    final appDir = _overrideAppDir ?? await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory('${appDir.path}/$_cacheDir');
    await _initEncryption();
    await _clearCacheOnUpgrade();
    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }
    _initialized = true;
  }

  Future<void> _initEncryption() async {
    try {
      String? keyBase64 = await _secureStorage.read(key: _encryptionKeyKey);
      if (keyBase64 == null) {
        final key = encrypt.Key.fromSecureRandom(32);
        keyBase64 = base64.encode(key.bytes);
        await _secureStorage.write(key: _encryptionKeyKey, value: keyBase64);
        LogService.instance.log(
          'WebViewState',
          'Generated new encryption key',
        );
      }
      final keyBytes = base64.decode(keyBase64);
      final key = encrypt.Key(Uint8List.fromList(keyBytes));
      _iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
      _encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.cbc),
      );
    } catch (e) {
      LogService.instance.log(
        'WebViewState',
        'Error initializing encryption: $e',
        level: LogLevel.error,
      );
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
      if (lastVersion != null && _cacheDirectory != null) {
        try {
          if (await _cacheDirectory!.exists()) {
            await _cacheDirectory!.delete(recursive: true);
          }
        } catch (e) {
          LogService.instance.log(
            'WebViewState',
            'Error clearing cache on upgrade: $e',
            level: LogLevel.error,
          );
        }
        // Rotate the AES key alongside the bytes — old ciphertext
        // wouldn't decrypt with the new key anyway, but explicit
        // rotation matches the HTML cache pattern.
        try {
          await _secureStorage.delete(key: _encryptionKeyKey);
          await _initEncryption();
        } catch (_) {
          // Best effort.
        }
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

  File _fileFor(String siteId) {
    return File('${_cacheDirectory!.path}/$siteId.enc');
  }

  @override
  Future<void> saveState(String siteId, Uint8List state) async {
    if (state.isEmpty) return;
    if (!_initialized) await initialize();
    if (_cacheDirectory == null || _encrypter == null || _iv == null) return;
    try {
      final encoded = base64.encode(state);
      final cipher = _encrypter!.encrypt(encoded, iv: _iv).base64;
      await _fileFor(siteId).writeAsString(cipher);
      LogService.instance.log(
        'WebViewState',
        'Saved ${state.length} bytes for site $siteId (encrypted)',
      );
    } catch (e) {
      LogService.instance.log(
        'WebViewState',
        'Error saving state for $siteId: $e',
        level: LogLevel.error,
      );
    }
  }

  @override
  Future<Uint8List?> loadState(String siteId) async {
    if (!_initialized) await initialize();
    if (_cacheDirectory == null || _encrypter == null || _iv == null) {
      return null;
    }
    try {
      final f = _fileFor(siteId);
      if (!await f.exists()) return null;
      final cipher = await f.readAsString();
      final decoded = _encrypter!.decrypt64(cipher, iv: _iv);
      final bytes = base64.decode(decoded);
      return Uint8List.fromList(bytes);
    } catch (e) {
      LogService.instance.log(
        'WebViewState',
        'Error loading state for $siteId: $e',
        level: LogLevel.error,
      );
      // Corrupt entry — defensive: remove so a re-save can succeed
      // and we don't keep failing loads in a hot loop.
      try {
        await _fileFor(siteId).delete();
      } catch (_) {}
      return null;
    }
  }

  @override
  Future<void> removeState(String siteId) async {
    if (!_initialized) await initialize();
    if (_cacheDirectory == null) return;
    try {
      final f = _fileFor(siteId);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (e) {
      LogService.instance.log(
        'WebViewState',
        'Error deleting state for $siteId: $e',
        level: LogLevel.error,
      );
    }
  }

  @override
  Future<int> removeOrphans(Set<String> activeSiteIds) async {
    if (!_initialized) await initialize();
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) {
      return 0;
    }
    var removed = 0;
    try {
      final entries = await _cacheDirectory!.list().toList();
      for (final entity in entries) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.enc')) continue;
        final filename = entity.path.split('/').last;
        final siteId = filename.replaceAll('.enc', '');
        if (!activeSiteIds.contains(siteId)) {
          await entity.delete();
          removed++;
        }
      }
      if (removed > 0) {
        LogService.instance.log(
          'WebViewState',
          'Removed $removed orphan state file(s)',
        );
      }
    } catch (e) {
      LogService.instance.log(
        'WebViewState',
        'Error sweeping orphan state files: $e',
        level: LogLevel.error,
      );
    }
    return removed;
  }

  @override
  Future<Set<String>> siteIds() async {
    if (!_initialized) await initialize();
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) {
      return const <String>{};
    }
    final result = <String>{};
    try {
      final entries = await _cacheDirectory!.list().toList();
      for (final entity in entries) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.enc')) continue;
        final filename = entity.path.split('/').last;
        result.add(filename.replaceAll('.enc', ''));
      }
    } catch (_) {
      // Best effort.
    }
    return result;
  }
}
