import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// Service to cache HTML content per site for offline viewing and faster loads.
/// Cache is AES encrypted and cleared on app upgrades.
class HtmlCacheService {
  static const String _versionKey = 'html_cache_version';
  static const String _cacheDir = 'html_cache';
  static const String _encryptionKeyKey = 'html_cache_encryption_key';

  static HtmlCacheService? _instance;
  static HtmlCacheService get instance => _instance ??= HtmlCacheService._();

  HtmlCacheService._();

  Directory? _cacheDirectory;
  encrypt.Encrypter? _encrypter;
  encrypt.IV? _iv;

  /// In-memory cache for sync access during build
  final Map<String, String> _memoryCache = {};

  final _secureStorage = const FlutterSecureStorage();

  /// Initialize the cache service. Call on app startup.
  Future<void> initialize() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory('${appDir.path}/$_cacheDir');

    // Initialize encryption
    await _initEncryption();

    // Clear cache on version upgrade
    await _clearCacheOnUpgrade();

    // Ensure cache directory exists
    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }

    // Pre-load all cached HTML into memory for sync access
    await _preloadCache();
  }

  /// Initialize AES encryption with key from secure storage
  Future<void> _initEncryption() async {
    try {
      // Try to get existing key
      String? keyBase64 = await _secureStorage.read(key: _encryptionKeyKey);

      if (keyBase64 == null) {
        // Generate new 256-bit key
        final key = encrypt.Key.fromSecureRandom(32);
        keyBase64 = base64.encode(key.bytes);
        await _secureStorage.write(key: _encryptionKeyKey, value: keyBase64);
        if (kDebugMode) {
          debugPrint('[HtmlCache] Generated new encryption key');
        }
      }

      final keyBytes = base64.decode(keyBase64);
      final key = encrypt.Key(Uint8List.fromList(keyBytes));
      // Use a fixed IV derived from key (first 16 bytes) for deterministic encryption
      _iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
      _encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));

      if (kDebugMode) {
        debugPrint('[HtmlCache] Encryption initialized');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error initializing encryption: $e');
      }
    }
  }

  String? _encrypt(String plaintext) {
    if (_encrypter == null || _iv == null) return null;
    try {
      return _encrypter!.encrypt(plaintext, iv: _iv).base64;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Encryption error: $e');
      }
      return null;
    }
  }

  String? _decrypt(String ciphertext) {
    if (_encrypter == null || _iv == null) return null;
    try {
      return _encrypter!.decrypt64(ciphertext, iv: _iv);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Decryption error: $e');
      }
      return null;
    }
  }

  /// Pre-load all cached HTML files into memory
  /// Files that fail to decrypt are discarded (deleted)
  Future<void> _preloadCache() async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return;

    try {
      final files = await _cacheDirectory!.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.enc')) {
          try {
            final encrypted = await entity.readAsString();
            final decrypted = _decrypt(encrypted);
            if (decrypted != null) {
              final newlineIndex = decrypted.indexOf('\n');
              if (newlineIndex != -1) {
                final siteId = entity.path.split('/').last.replaceAll('.enc', '');
                final html = decrypted.substring(newlineIndex + 1);
                _memoryCache[siteId] = html;
              } else {
                // Invalid format - discard
                await entity.delete();
                if (kDebugMode) {
                  debugPrint('[HtmlCache] Discarded invalid cache file: ${entity.path}');
                }
              }
            } else {
              // Decryption failed - discard (key may have changed)
              await entity.delete();
              if (kDebugMode) {
                debugPrint('[HtmlCache] Discarded undecryptable cache file: ${entity.path}');
              }
            }
          } catch (e) {
            // File read/decrypt error - discard
            await entity.delete();
            if (kDebugMode) {
              debugPrint('[HtmlCache] Discarded corrupted cache file: ${entity.path} ($e)');
            }
          }
        }
      }
      if (kDebugMode) {
        debugPrint('[HtmlCache] Pre-loaded ${_memoryCache.length} cached pages');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error pre-loading cache: $e');
      }
    }
  }

  /// Get cached HTML synchronously (from pre-loaded memory cache)
  String? getHtmlSync(String siteId) {
    return _memoryCache[siteId];
  }

  Future<void> _clearCacheOnUpgrade() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();

    final currentVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    final lastVersion = prefs.getString(_versionKey);

    if (lastVersion != null && lastVersion != currentVersion) {
      // Version changed - clear the HTML cache and generate new key
      if (_cacheDirectory != null && await _cacheDirectory!.exists()) {
        await _cacheDirectory!.delete(recursive: true);
        if (kDebugMode) {
          debugPrint('[HtmlCache] Cleared cache on upgrade from $lastVersion to $currentVersion');
        }
      }
      _memoryCache.clear();
      // Generate new encryption key on upgrade
      await _secureStorage.delete(key: _encryptionKeyKey);
      await _initEncryption();
    }

    await prefs.setString(_versionKey, currentVersion);
  }

  /// Get the cache file path for a site
  File _getCacheFile(String siteId) {
    return File('${_cacheDirectory!.path}/$siteId.enc');
  }

  /// Max HTML size to cache (10MB)
  static const int _maxHtmlSize = 10 * 1024 * 1024;

  /// Save HTML content for a site (encrypted)
  Future<void> saveHtml(String siteId, String html, String url) async {
    if (_cacheDirectory == null || _encrypter == null) return;

    // Skip if HTML is too large
    if (html.length > _maxHtmlSize) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Skipping save for $siteId - HTML too large (${html.length} bytes > $_maxHtmlSize)');
      }
      return;
    }

    try {
      final file = _getCacheFile(siteId);

      // Store URL as first line, then HTML
      final plaintext = '$url\n$html';
      final encrypted = _encrypt(plaintext);
      if (encrypted == null) return;

      await file.writeAsString(encrypted);

      // Update memory cache
      _memoryCache[siteId] = html;

      if (kDebugMode) {
        debugPrint('[HtmlCache] Saved ${html.length} bytes for site $siteId (encrypted)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error saving HTML for $siteId: $e');
      }
    }
  }

  /// Load cached HTML for a site (decrypted)
  /// Returns (url, html) tuple or null if not cached
  Future<(String, String)?> loadHtml(String siteId) async {
    if (_cacheDirectory == null || _encrypter == null) return null;

    try {
      final file = _getCacheFile(siteId);
      if (!await file.exists()) return null;

      final encrypted = await file.readAsString();
      final decrypted = _decrypt(encrypted);
      if (decrypted == null) return null;

      final newlineIndex = decrypted.indexOf('\n');
      if (newlineIndex == -1) return null;

      final url = decrypted.substring(0, newlineIndex);
      final html = decrypted.substring(newlineIndex + 1);

      if (kDebugMode) {
        debugPrint('[HtmlCache] Loaded ${html.length} bytes for site $siteId (decrypted)');
      }

      return (url, html);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[HtmlCache] Error loading HTML for $siteId: $e');
      }
      return null;
    }
  }

  /// Check if cached HTML exists for a site
  Future<bool> hasCache(String siteId) async {
    if (_cacheDirectory == null) return false;
    final file = _getCacheFile(siteId);
    return file.exists();
  }

  /// Delete cached HTML for a site
  Future<void> deleteCache(String siteId) async {
    if (_cacheDirectory == null) return;
    final file = _getCacheFile(siteId);
    if (await file.exists()) {
      await file.delete();
    }
    _memoryCache.remove(siteId);
  }

  /// Delete cached HTML for sites not in the provided set
  Future<void> removeOrphanedCaches(Set<String> activeSiteIds) async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return;

    final files = await _cacheDirectory!.list().toList();
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.enc')) {
        final filename = entity.path.split('/').last;
        final siteId = filename.replaceAll('.enc', '');
        if (!activeSiteIds.contains(siteId)) {
          await entity.delete();
          _memoryCache.remove(siteId);
          if (kDebugMode) {
            debugPrint('[HtmlCache] Removed orphaned cache for $siteId');
          }
        }
      }
    }
  }
}
