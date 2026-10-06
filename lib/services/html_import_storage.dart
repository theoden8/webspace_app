import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/keychain_aead.dart';
import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The site an imported HTML file becomes, named after the file without its
/// extension. Three slashes (empty authority): `file://name.html` parses the
/// name as the host, and Chromium rejects that as ERR_INVALID_URL whenever
/// the stored HTML is unavailable.
({String url, String name}) importedFileSite(String fileName) => (
      url: 'file:///$fileName',
      name: fileName.replaceAll(RegExp(r'\.html?$', caseSensitive: false), ''),
    );

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
  })  : _secureStorage = secureStorage ?? Keystores.aeadKeys,
        _overrideStore = store;

  final FlutterSecureStorage _secureStorage;
  final FileStore? _overrideStore;

  FileStore? _store;
  KeychainAead? _aead;

  /// In-memory mirror used by [getHtmlSync] so [InAppWebViewInitialData]
  /// can be constructed without an awaited disk read at build time.
  final Map<String, String> _memoryStore = {};

  Future<void> initialize() async {
    _store = _overrideStore ?? defaultFileStore(_storageDir);

    _aead = await KeychainAead.open(_secureStorage, _encryptionKeyKey,
        logTag: 'HtmlImport');

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

  /// Decrypts a stored blob, reporting whether it was still in the AES-CBC
  /// form imports used before GCM, so the caller can reseal it. Imports are
  /// the user's only copy, so those blobs stay readable.
  ({String plaintext, bool legacy})? _decrypt(String wire) {
    final aead = _aead;
    if (aead == null) return null;
    final sealed = aead.unseal(wire);
    if (sealed != null) return (plaintext: sealed, legacy: false);
    final legacy = aead.unsealLegacyCbc(wire);
    if (legacy == null) {
      LogService.instance.log('HtmlImport', 'Import does not decrypt',
          level: LogLevel.error);
      return null;
    }
    return (plaintext: legacy, legacy: true);
  }

  /// Rewrites a legacy AES-CBC blob under GCM. Best-effort: a failure leaves
  /// the readable legacy file in place.
  Future<void> _upgradeBlob(String siteId, String plaintext) async {
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return;
    try {
      await store.writeText(_importFileName(siteId), aead.seal(plaintext));
    } on Exception catch (e) {
      LogService.instance.log(
        'HtmlImport',
        'Could not re-encrypt import for $siteId: $e',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
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
              final newlineIndex = decrypted.plaintext.indexOf('\n');
              if (newlineIndex != -1) {
                final siteId = name.replaceAll('.enc', '');
                final html = decrypted.plaintext.substring(newlineIndex + 1);
                _memoryStore[siteId] = html;
                if (decrypted.legacy) {
                  await _upgradeBlob(siteId, decrypted.plaintext);
                }
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
          } on Exception catch (e) {
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
    } on Exception catch (e) {
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
    final aead = _aead;
    if (store == null || aead == null) return;

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
      await store.writeText(_importFileName(siteId), aead.seal('$url\n$html'));
      _memoryStore[siteId] = html;

      LogService.instance.log(
        'HtmlImport',
        'Saved ${html.length} bytes for site $siteId (encrypted)',
        sensitivity: LogSensitivity.sensitive,
      );
    } on Exception catch (e) {
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
    if (store == null || _aead == null) return null;

    try {
      final encrypted = await store.readText(_importFileName(siteId));
      if (encrypted == null) return null;

      final decrypted = _decrypt(encrypted);
      if (decrypted == null) return null;

      final newlineIndex = decrypted.plaintext.indexOf('\n');
      if (newlineIndex == -1) return null;

      if (decrypted.legacy) {
        await _upgradeBlob(siteId, decrypted.plaintext);
      }

      final url = decrypted.plaintext.substring(0, newlineIndex);
      final html = decrypted.plaintext.substring(newlineIndex + 1);

      return (url, html);
    } on Exception catch (e) {
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
