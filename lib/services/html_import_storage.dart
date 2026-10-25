import 'package:flutter/services.dart' show PlatformException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/file_import_document.dart';
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
/// Imports are the only copy of the data the user picked off their device,
/// so this store survives upgrades.
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
    FileStore? retiredCache,
  })  : _secureStorage = secureStorage ?? Keystores.aeadKeys,
        _overrideStore = store,
        _retiredCache = retiredCache;

  final FlutterSecureStorage _secureStorage;
  final FileStore? _overrideStore;
  final FileStore? _retiredCache;

  FileStore? _store;
  KeychainAead? _aead;

  /// In-memory mirror used by [getHtmlSync] so [InAppWebViewInitialData]
  /// can be constructed without an awaited disk read at build time.
  final Map<SiteId, String> _memoryStore = {};

  Future<void> initialize() async {
    _store = _overrideStore ?? defaultFileStore(_storageDir);

    _aead = await KeychainAead.open(_secureStorage, keyName: _encryptionKeyKey,
        logTag: LogTag.htmlImport);

    await _store!.ensure();
  }

  /// Decrypt a single import into the in-memory store so a subsequent
  /// [getHtmlSync] hits. Idempotent; a no-op when the site has no import on
  /// disk. Lets the cold-start path load
  /// only the imports for sites that actually build, instead of every import.
  Future<void> preloadOne(SiteId siteId) async {
    if (_memoryStore.containsKey(siteId)) return;
    final res = await loadHtml(siteId);
    if (res != null) _memoryStore[siteId] = res.$2;
  }

  /// Decrypts a stored blob, reporting whether it was still in the AES-CBC
  /// form imports used before GCM, so the caller can reseal it. Imports are
  /// the user's only copy, so those blobs stay readable.
  Future<({String plaintext, bool legacy})?> _decrypt(String wire) async {
    final aead = _aead;
    if (aead == null) return null;
    final sealed = await aead.unseal(wire);
    if (sealed != null) return (plaintext: sealed, legacy: false);
    final legacy = aead.unsealLegacyCbc(wire);
    if (legacy == null) {
      LogTag.htmlImport.error('Import does not decrypt');
      return null;
    }
    return (plaintext: legacy, legacy: true);
  }

  /// Rewrites a legacy AES-CBC blob under GCM. Best-effort: a failure leaves
  /// the readable legacy file in place.
  Future<void> _upgradeBlob(SiteId siteId, {required String plaintext}) async {
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return;
    try {
      await store.writeText(_importFileName(siteId),
          contents: await aead.seal(plaintext));
    } on IOException catch (e) {
      LogTag.htmlImport.warning(
          'Could not re-encrypt import for $siteId: $e', sensitive: true);
    }
  }

  String? getHtmlSync(SiteId siteId) {
    return _memoryStore[siteId];
  }

  String _importFileName(SiteId siteId) => '$siteId.enc';

  /// Per-site upper bound. Imports are user-supplied so this is a sanity
  /// gate, not a deduplication-or-eviction policy — the legacy cache used
  /// the same 10 MB ceiling.
  static const int _maxHtmlSize = 10 * 1024 * 1024;

  Future<void> saveHtml(SiteId siteId,
      {required String html, required String url}) async {
    final store = _store;
    final aead = _aead;
    if (store == null || aead == null) return;

    if (html.length > _maxHtmlSize) {
      LogTag.htmlImport.warning(
          'Skipping save for $siteId - HTML too large (${html.length} bytes > $_maxHtmlSize)',
          sensitive: true);
      return;
    }

    try {
      await store.writeText(_importFileName(siteId),
          contents: await aead.seal('$url\n$html'));
      _memoryStore[siteId] = html;

      LogTag.htmlImport.debug(
          'Saved ${html.length} bytes for site $siteId (encrypted)',
          sensitive: true);
    } on IOException catch (e) {
      LogTag.htmlImport
          .error('Error saving HTML for $siteId: $e', sensitive: true);
    }
  }

  Future<(String, String)?> loadHtml(SiteId siteId) async {
    final store = _store;
    if (store == null || _aead == null) return null;

    try {
      final encrypted = await store.readText(_importFileName(siteId));
      if (encrypted == null) return null;

      final decrypted = await _decrypt(encrypted);
      if (decrypted == null) return null;

      final newlineIndex = decrypted.plaintext.indexOf('\n');
      if (newlineIndex == -1) return null;

      if (decrypted.legacy) {
        await _upgradeBlob(siteId, plaintext: decrypted.plaintext);
      }

      final url = decrypted.plaintext.substring(0, newlineIndex);
      final html = decrypted.plaintext.substring(newlineIndex + 1);

      return (url, html);
    } on IOException catch (e) {
      LogTag.htmlImport.error(
          'Error loading HTML for $siteId: $e', sensitive: true);
      return null;
    }
  }

  Future<bool> hasImport(SiteId siteId) async {
    final store = _store;
    if (store == null) return false;
    return store.exists(_importFileName(siteId));
  }

  Future<void> removeOrphanedImports(Set<SiteId> activeSiteIds) async {
    final store = _store;
    if (store == null) return;

    final files = await store.list();
    for (final name in files) {
      if (name.endsWith('.enc')) {
        final siteId = name.replaceAll('.enc', '');
        if (!activeSiteIds.contains(siteId)) {
          await store.delete(name);
          _memoryStore.remove(siteId);
          LogTag.htmlImport.info(
              'Removed orphaned import for $siteId', sensitive: true);
        }
      }
    }
  }

  /// The page snapshots releases before this one kept beside the imports,
  /// each sealed under the cache's own key, and the version they last ran
  /// under, which they wrote at every launch.
  static const String _retiredCacheDir = 'html_cache';
  static const String _retiredCacheKey = 'html_cache_encryption_key';
  static const String _retiredCacheVersion = 'html_cache_version';

  /// Deletes those snapshots: their files, their key and their version
  /// stamp, once. A release before v0.3.3 kept imports among them, so an
  /// import found only there is carried into this store first; while the
  /// key cannot be read, nothing is deleted, and the next launch tries again.
  Future<void> retireSnapshotCache() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_retiredCacheVersion)) return;
    final cache = _retiredCache ?? defaultFileStore(_retiredCacheDir);
    try {
      final names = await cache.list();
      if (names.isNotEmpty) {
        final aead = await KeychainAead.open(_secureStorage,
            keyName: _retiredCacheKey, logTag: LogTag.htmlImport);
        if (aead == null) return;
        await _carryImports(cache, names: names, aead: aead);
      }
      await cache.deleteAll();
      await _secureStorage.delete(key: _retiredCacheKey);
      await prefs.remove(_retiredCacheVersion);
    } on IOException catch (e) {
      LogTag.htmlImport.error('Retiring the snapshot cache failed: $e');
    } on PlatformException catch (e) {
      LogTag.htmlImport.error('Retiring the snapshot cache failed: $e');
    }
  }

  /// Each snapshot holds `url\nhtml`; one whose url is a file:// handle is
  /// an import, kept unless this store already holds that site.
  Future<void> _carryImports(FileStore cache,
      {required List<String> names, required KeychainAead aead}) async {
    var carried = 0;
    for (final name in names) {
      if (!name.endsWith('.enc')) continue;
      final siteId = SiteId.parse(name.substring(0, name.length - 4));
      if (siteId == null || await hasImport(siteId)) continue;
      final wire = await cache.readText(name);
      final opened = wire == null ? null : await aead.unseal(wire);
      final nl = opened?.indexOf('\n') ?? -1;
      if (opened == null || nl == -1) continue;
      final url = opened.substring(0, nl);
      if (!isFileImportUrl(url)) continue;
      await saveHtml(siteId, html: opened.substring(nl + 1), url: url);
      carried++;
    }
    if (carried > 0) {
      LogTag.htmlImport.info('Carried $carried import(s) out of the snapshot cache');
    }
  }

  /// Inline style prepended to an import's page for a dark-theme site so the
  /// pre-paint frame matches the app/webview theme instead of flashing white.
  ///
  /// `color-scheme: dark` hints the engine to use dark scrollbars and form
  /// controls. The background rule is a hard override so content rendered
  /// against `<html>`/`<body>` with no explicit background doesn't flash
  /// default white. Real site styles still load afterward and take over.
  static const String _darkPrelude =
      '<meta name="color-scheme" content="dark">'
      '<style id="__ws_cache_prelude">'
      'html,body{background:#111 !important;color-scheme:dark}'
      '</style>';

  /// Prepend [_darkPrelude] to [html] when [dark] is true. No-op if the
  /// prelude is already present.
  static String applyThemePrelude(String html, {required bool dark}) {
    if (!dark) return html;
    if (html.contains('id="__ws_cache_prelude"')) return html;
    final headMatch =
        RegExp(r'<head(?:\s[^>]*)?>', caseSensitive: false).firstMatch(html);
    if (headMatch != null) {
      return html.replaceRange(headMatch.end, headMatch.end, _darkPrelude);
    }
    // No <head> tag — prepend so the prelude still reaches the parser.
    return '$_darkPrelude$html';
  }
}
