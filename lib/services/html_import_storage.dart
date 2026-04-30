import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:webspace/services/log_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// Persistent AES-encrypted storage for user-imported HTML files.
///
/// Distinct from [HtmlCacheService]: imports are the only copy of the
/// data the user picked off their device, so wiping them on app
/// upgrade would destroy content they explicitly imported. This store
/// survives upgrades. Cached snapshots of fetched pages stay in
/// [HtmlCacheService] (re-fetchable, safe to drop).
class HtmlImportStorage {
  static const String _storageDir = 'html_imports';
  static const String _encryptionKeyKey = 'html_import_encryption_key';

  static HtmlImportStorage? _instance;
  static HtmlImportStorage get instance => _instance ??= HtmlImportStorage();

  /// Tests construct an instance directly with overrides; the production
  /// singleton uses the default-arg path.
  HtmlImportStorage({
    FlutterSecureStorage? secureStorage,
    Directory? overrideAppDir,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _overrideAppDir = overrideAppDir;

  final FlutterSecureStorage _secureStorage;
  final Directory? _overrideAppDir;

  Directory? _storageDirectory;
  encrypt.Encrypter? _encrypter;
  encrypt.IV? _iv;

  /// In-memory mirror used by [getHtmlSync] so [InAppWebViewInitialData]
  /// can be constructed without an awaited disk read at build time.
  final Map<String, String> _memoryStore = {};

  Future<void> initialize() async {
    final appDir = _overrideAppDir ?? await getApplicationDocumentsDirectory();
    _storageDirectory = Directory('${appDir.path}/$_storageDir');

    await _initEncryption();

    if (!await _storageDirectory!.exists()) {
      await _storageDirectory!.create(recursive: true);
    }
  }

  /// Decrypt every file on disk into [_memoryStore]. Mirrors
  /// [HtmlCacheService.preloadCache] so `getHtmlSync(siteId)` is
  /// answerable synchronously during `WebSpacePage.build`.
  Future<void> preloadAll() => _preloadAll();

  Future<void> _initEncryption() async {
    try {
      String? keyBase64 = await _secureStorage.read(key: _encryptionKeyKey);

      if (keyBase64 == null) {
        final key = encrypt.Key.fromSecureRandom(32);
        keyBase64 = base64.encode(key.bytes);
        await _secureStorage.write(key: _encryptionKeyKey, value: keyBase64);
        LogService.instance.log('HtmlImport', 'Generated new encryption key', level: LogLevel.info);
      }

      final keyBytes = base64.decode(keyBase64);
      final key = encrypt.Key(Uint8List.fromList(keyBytes));
      _iv = encrypt.IV(Uint8List.fromList(keyBytes.sublist(0, 16)));
      _encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc));

      LogService.instance.log('HtmlImport', 'Encryption initialized');
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Error initializing encryption: $e', level: LogLevel.error);
    }
  }

  String? _encrypt(String plaintext) {
    if (_encrypter == null || _iv == null) return null;
    try {
      return _encrypter!.encrypt(plaintext, iv: _iv).base64;
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Encryption error: $e', level: LogLevel.error);
      return null;
    }
  }

  String? _decrypt(String ciphertext) {
    if (_encrypter == null || _iv == null) return null;
    try {
      return _encrypter!.decrypt64(ciphertext, iv: _iv);
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Decryption error: $e', level: LogLevel.error);
      return null;
    }
  }

  Future<void> _preloadAll() async {
    if (_storageDirectory == null || !await _storageDirectory!.exists()) return;

    try {
      final files = await _storageDirectory!.list().toList();
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
                _memoryStore[siteId] = html;
              } else {
                LogService.instance.log('HtmlImport', 'Discarded invalid import file: ${entity.path}', level: LogLevel.warning);
                await entity.delete();
              }
            } else {
              LogService.instance.log('HtmlImport', 'Discarded undecryptable import file: ${entity.path}', level: LogLevel.warning);
              await entity.delete();
            }
          } catch (e) {
            LogService.instance.log('HtmlImport', 'Discarded corrupted import file: ${entity.path} ($e)', level: LogLevel.warning);
            await entity.delete();
          }
        }
      }
      LogService.instance.log('HtmlImport', 'Pre-loaded ${_memoryStore.length} imported pages');
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Error pre-loading imports: $e', level: LogLevel.error);
    }
  }

  String? getHtmlSync(String siteId) {
    return _memoryStore[siteId];
  }

  File _getImportFile(String siteId) {
    return File('${_storageDirectory!.path}/$siteId.enc');
  }

  /// Per-site upper bound. Imports are user-supplied so this is a sanity
  /// gate, not a deduplication-or-eviction policy — the legacy cache used
  /// the same 10 MB ceiling.
  static const int _maxHtmlSize = 10 * 1024 * 1024;

  Future<void> saveHtml(String siteId, String html, String url) async {
    if (_storageDirectory == null || _encrypter == null) return;

    if (html.length > _maxHtmlSize) {
      LogService.instance.log('HtmlImport', 'Skipping save for $siteId - HTML too large (${html.length} bytes > $_maxHtmlSize)', level: LogLevel.warning);
      return;
    }

    try {
      final file = _getImportFile(siteId);
      final plaintext = '$url\n$html';
      final encrypted = _encrypt(plaintext);
      if (encrypted == null) return;

      await file.writeAsString(encrypted);
      _memoryStore[siteId] = html;

      LogService.instance.log('HtmlImport', 'Saved ${html.length} bytes for site $siteId (encrypted)');
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Error saving HTML for $siteId: $e', level: LogLevel.error);
    }
  }

  Future<(String, String)?> loadHtml(String siteId) async {
    if (_storageDirectory == null || _encrypter == null) return null;

    try {
      final file = _getImportFile(siteId);
      if (!await file.exists()) return null;

      final encrypted = await file.readAsString();
      final decrypted = _decrypt(encrypted);
      if (decrypted == null) return null;

      final newlineIndex = decrypted.indexOf('\n');
      if (newlineIndex == -1) return null;

      final url = decrypted.substring(0, newlineIndex);
      final html = decrypted.substring(newlineIndex + 1);

      return (url, html);
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Error loading HTML for $siteId: $e', level: LogLevel.error);
      return null;
    }
  }

  Future<bool> hasImport(String siteId) async {
    if (_storageDirectory == null) return false;
    final file = _getImportFile(siteId);
    return file.exists();
  }

  Future<void> deleteImport(String siteId) async {
    if (_storageDirectory == null) return;
    final file = _getImportFile(siteId);
    if (await file.exists()) {
      await file.delete();
    }
    _memoryStore.remove(siteId);
  }

  Future<void> removeOrphanedImports(Set<String> activeSiteIds) async {
    if (_storageDirectory == null || !await _storageDirectory!.exists()) return;

    final files = await _storageDirectory!.list().toList();
    for (final entity in files) {
      if (entity is File && entity.path.endsWith('.enc')) {
        final filename = entity.path.split('/').last;
        final siteId = filename.replaceAll('.enc', '');
        if (!activeSiteIds.contains(siteId)) {
          await entity.delete();
          _memoryStore.remove(siteId);
          LogService.instance.log('HtmlImport', 'Removed orphaned import for $siteId', level: LogLevel.info);
        }
      }
    }
  }
}
