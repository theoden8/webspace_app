import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/site_icon_engine.dart';

class _Entry {
  _Entry(this.icon, {required this.thisLaunch});

  final SiteIcon icon;
  final bool thisLaunch;
}

/// The icon each site's own webview reported (ICON-009), keyed by the site's
/// home URL. Held in memory so the drawer can render it synchronously, and
/// written to disk only for sites whose state may outlive the session.
class SiteIconStore {
  SiteIconStore({FileStore? store}) : _overrideStore = store;

  static SiteIconStore instance = SiteIconStore();

  static const String _dir = 'site_icons';

  final FileStore? _overrideStore;
  FileStore? _store;
  final Map<String, _Entry> _entries = {};
  final StreamController<String?> _changes =
      StreamController<String?>.broadcast();
  Future<void> _io = Future.value();

  /// Fires the site URL whenever its icon is replaced or removed, and null
  /// once the icons on disk have been loaded.
  Stream<String?> get changes => _changes.stream;

  static String _name(String siteUrl) =>
      '${sha256.convert(utf8.encode(siteUrl))}.png';

  Future<void> initialize() {
    final store = _store ??= _overrideStore ?? defaultFileStore(_dir);
    return _io = _io.then((_) async {
      var loaded = false;
      for (final name in await store.list()) {
        if (_entries.containsKey(name)) continue;
        final bytes = await store.readBytes(name);
        final size = bytes == null ? null : pngDimensions(bytes);
        if (size == null) {
          await store.delete(name);
          continue;
        }
        _entries[name] = _Entry(
          SiteIcon(bytes!, size.width, size.height),
          thisLaunch: false,
        );
        loaded = true;
      }
      if (loaded) _changes.add(null);
    }).catchError((Object _) {});
  }

  Uint8List? get(String siteUrl) => _entries[_name(siteUrl)]?.icon.png;

  /// Offer an icon the site's webview reported. [persist] is false for sites
  /// whose state must not outlive the session (incognito, archive tier).
  Future<void> offer(String siteUrl, SiteIcon icon,
      {required bool persist}) async {
    final name = _name(siteUrl);
    final current = _entries[name];
    if (!shouldReplaceSiteIcon(
      storedEdge: current?.icon.edge,
      storedThisLaunch: current?.thisLaunch ?? false,
      newEdge: icon.edge,
    )) {
      return;
    }
    _entries[name] = _Entry(icon, thisLaunch: true);
    _changes.add(siteUrl);
    await _sync(name, persist: persist);
  }

  Future<void> remove(String siteUrl) async {
    final name = _name(siteUrl);
    final had = _entries.remove(name) != null;
    await _sync(name, persist: false);
    if (had) _changes.add(siteUrl);
  }

  // Icons for one page arrive in a burst; serialising the writes keeps two of
  // them from truncating the same file under each other, and writing whatever
  // is in memory when the turn comes keeps the file on the latest icon.
  Future<void> _sync(String name, {required bool persist}) {
    final store = _store;
    if (store == null) return Future.value();
    return _io = _io.then((_) async {
      final entry = _entries[name];
      if (persist && entry != null) {
        await store.writeBytes(name, entry.icon.png);
      } else {
        await store.delete(name);
      }
    }).catchError((Object _) {});
  }

  /// Drop every stored icon whose site is not in [persistedSiteUrls]: sites
  /// that were deleted, edited to another URL, or turned incognito.
  Future<void> removeOrphans(Set<String> persistedSiteUrls) async {
    final store = _store;
    if (store == null) return;
    final keep = persistedSiteUrls.map(_name).toSet();
    await (_io = _io.then((_) async {
      for (final name in await store.list()) {
        if (keep.contains(name)) continue;
        _entries.remove(name);
        await store.delete(name);
      }
    }).catchError((Object _) {}));
  }
}
