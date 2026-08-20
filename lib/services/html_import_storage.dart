import 'dart:convert';
import 'dart:typed_data';
import 'package:webspace/services/file_store.dart';
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
    FileStore? store,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _overrideStore = store;

  final FlutterSecureStorage _secureStorage;
  final FileStore? _overrideStore;

  FileStore? _store;
  encrypt.Encrypter? _encrypter;
  encrypt.IV? _iv;

  /// In-memory mirror used by [getHtmlSync] so [InAppWebViewInitialData]
  /// can be constructed without an awaited disk read at build time.
  final Map<String, String> _memoryStore = {};

  Future<void> initialize() async {
    _store = _overrideStore ?? defaultFileStore(_storageDir);

    await _initEncryption();

    await _store!.ensure();
  }

  /// Decrypt every file on disk into [_memoryStore]. Mirrors
  /// [HtmlCacheService.preloadCache] so `getHtmlSync(siteId)` is
  /// answerable synchronously during `WebSpacePage.build`.
  Future<void> preloadAll() => _preloadAll();

  /// Decrypt a single import into the in-memory store so a subsequent
  /// [getHtmlSync] hits without the bulk [preloadAll] pass. Idempotent; a
  /// no-op when the site has no import on disk. Lets the cold-start path load
  /// only the imports for sites that actually build, instead of every import.
  Future<void> preloadOne(String siteId) async {
    if (_memoryStore.containsKey(siteId)) return;
    final res = await loadHtml(siteId);
    if (res != null) _memoryStore[siteId] = res.$2;
  }

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
    final store = _store;
    if (store == null) return;

    try {
      final files = await store.list();
      var skipped = 0;
      for (final name in files) {
        if (name.endsWith('.enc')) {
          try {
            final encrypted = await store.readText(name);
            final decrypted = encrypted == null ? null : _decrypt(encrypted);
            if (decrypted != null) {
              final newlineIndex = decrypted.indexOf('\n');
              if (newlineIndex != -1) {
                final siteId = name.replaceAll('.enc', '');
                final html = decrypted.substring(newlineIndex + 1);
                _memoryStore[siteId] = html;
              } else {
                // Imports are the only copy of user-supplied data — never
                // delete on parse failure. The fallback page renders if the
                // bytes can't be loaded, but the file stays on disk in case
                // the AES key is recoverable (e.g. flutter_secure_storage
                // returns the original key on a later launch after a
                // transient Android Keystore read failure).
                LogService.instance.log(
                  'HtmlImport',
                  'Skipping invalid import file (kept on disk): $name',
                  level: LogLevel.warning,
                  sensitivity: LogSensitivity.sensitive,
                );
                skipped++;
              }
            } else {
              LogService.instance.log(
                'HtmlImport',
                'Skipping undecryptable import file (kept on disk): $name',
                level: LogLevel.warning,
                sensitivity: LogSensitivity.sensitive,
              );
              skipped++;
            }
          } catch (e) {
            LogService.instance.log(
              'HtmlImport',
              'Skipping unreadable import file (kept on disk): $name ($e)',
              level: LogLevel.warning,
              sensitivity: LogSensitivity.sensitive,
            );
            skipped++;
          }
        }
      }
      LogService.instance.log('HtmlImport', 'Pre-loaded ${_memoryStore.length} imported pages (skipped $skipped unreadable file(s))');
    } catch (e) {
      LogService.instance.log('HtmlImport', 'Error pre-loading imports: $e', level: LogLevel.error);
    }
  }

  String? getHtmlSync(String siteId) {
    return _memoryStore[siteId];
  }

  String _importFileName(String siteId) => '$siteId.enc';

  /// Per-site upper bound. Imports are user-supplied so this is a sanity
  /// gate, not a deduplication-or-eviction policy — the legacy cache used
  /// the same 10 MB ceiling.
  static const int _maxHtmlSize = 10 * 1024 * 1024;

  Future<void> saveHtml(String siteId, String html, String url) async {
    final store = _store;
    if (store == null || _encrypter == null) return;

    if (html.length > _maxHtmlSize) {
      LogService.instance.log(
        'HtmlImport',
        'Skipping save for $siteId - HTML too large (${html.length} bytes > $_maxHtmlSize)',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    try {
      final plaintext = '$url\n$html';
      final encrypted = _encrypt(plaintext);
      if (encrypted == null) return;

      await store.writeText(_importFileName(siteId), encrypted);
      _memoryStore[siteId] = html;

      LogService.instance.log(
        'HtmlImport',
        'Saved ${html.length} bytes for site $siteId (encrypted)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (e) {
      LogService.instance.log(
        'HtmlImport',
        'Error saving HTML for $siteId: $e',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
    }
  }

  Future<(String, String)?> loadHtml(String siteId) async {
    final store = _store;
    if (store == null || _encrypter == null) return null;

    try {
      final encrypted = await store.readText(_importFileName(siteId));
      if (encrypted == null) return null;

      final decrypted = _decrypt(encrypted);
      if (decrypted == null) return null;

      final newlineIndex = decrypted.indexOf('\n');
      if (newlineIndex == -1) return null;

      final url = decrypted.substring(0, newlineIndex);
      final html = decrypted.substring(newlineIndex + 1);

      return (url, html);
    } catch (e) {
      LogService.instance.log(
        'HtmlImport',
        'Error loading HTML for $siteId: $e',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
      return null;
    }
  }

  Future<bool> hasImport(String siteId) async {
    final store = _store;
    if (store == null) return false;
    return store.exists(_importFileName(siteId));
  }

  Future<void> deleteImport(String siteId) async {
    final store = _store;
    if (store == null) return;
    await store.delete(_importFileName(siteId));
    _memoryStore.remove(siteId);
  }

  Future<void> removeOrphanedImports(Set<String> activeSiteIds) async {
    final store = _store;
    if (store == null) return;

    final files = await store.list();
    for (final name in files) {
      if (name.endsWith('.enc')) {
        final siteId = name.replaceAll('.enc', '');
        if (!activeSiteIds.contains(siteId)) {
          await store.delete(name);
          _memoryStore.remove(siteId);
          LogService.instance.log(
            'HtmlImport',
            'Removed orphaned import for $siteId',
            level: LogLevel.info,
            sensitivity: LogSensitivity.sensitive,
          );
        }
      }
    }
  }
}
