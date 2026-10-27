/// The web extensions imported on this device (WEBEXT-002): each one's
/// entry, saved in SharedPreferences, and its files, unpacked into a folder
/// of its own. A backup carries neither (WEBEXT-011).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/host_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/web_extension.dart';

/// Whether extensions are offered here now (WEBEXT-001): on a host that runs
/// them, with developer mode and the Web extensions switch on. Every
/// webview's plan and every Extensions row reads it.
bool get webExtensionsOffered =>
    hostRunsWebExtensions &&
    ExperimentalFeaturesService.instance.isEnabled(
      ExperimentalFeature.webExtensions,
    );

/// Where the library's extensions are unpacked. Every call but [folderOf]
/// fails with an [IOException] only.
abstract interface class ExtensionFolders {
  /// The absolute folder [id] is unpacked in.
  String folderOf(WebExtensionId id);

  /// Writes each of [files], keyed by its path inside the extension, into
  /// [id]'s folder.
  Future<void> unpack(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  });

  Future<void> delete(WebExtensionId id);

  /// The names of the folders present.
  Future<List<String>> names();
}

final class _HostExtensionFolders implements ExtensionFolders {
  _HostExtensionFolders(this.root);

  final String root;

  @override
  String folderOf(WebExtensionId id) => '$root/$id';

  @override
  Future<void> unpack(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  }) async {
    final folder = folderOf(id);
    for (final MapEntry(key: path, value: bytes) in files.entries) {
      final slash = path.lastIndexOf('/');
      await hostEnsureDirectory(
        slash < 0 ? folder : '$folder/${path.substring(0, slash)}',
      );
      await hostWriteFileBytes('$folder/$path', bytes: bytes);
    }
  }

  @override
  Future<void> delete(WebExtensionId id) => hostDeleteDirectory(folderOf(id));

  @override
  Future<List<String>> names() => hostListDirectoryNames(root);
}

class WebExtensionLibrary {
  WebExtensionLibrary._();
  static final WebExtensionLibrary instance = WebExtensionLibrary._();

  static const _prefsKey = 'webExtensionLibrary';
  static const _directory = 'web_extensions';

  ExtensionFolders? _folders;
  final ValueNotifier<List<InstalledExtension>> _installed = ValueNotifier(
    const [],
  );

  /// The extensions a site may switch on, in import order. Empty where the
  /// host runs none, or where their folders could not be found.
  ValueListenable<List<InstalledExtension>> get installed => _installed;

  /// Whether an import can be unpacked here.
  bool get available => _folders != null;

  /// Reads the library and removes any folder no entry names: one left by
  /// an import cut short, a removal cut short, or demo mode.
  Future<void> initialize({@visibleForTesting ExtensionFolders? folders}) async {
    if (folders == null && !hostRunsWebExtensions) return;
    final prefs = await SharedPreferences.getInstance();
    final entries = [
      for (final raw
          in readPrefAs<List<String>>(prefs, key: _prefsKey) ?? const [])
        ?_decode(raw),
    ];
    try {
      final found =
          folders ??
          _HostExtensionFolders(
              await hostEntryPath(_directory, kind: StoreKind.data));
      final named = {for (final e in entries) e.id as String};
      for (final name in await found.names()) {
        final id = WebExtensionId.parse(name);
        if (id != null && !named.contains(id)) await found.delete(id);
      }
      _folders = found;
    } on IOException catch (e) {
      LogTag.webExtension.info('library unavailable: $e');
      return;
    }
    _publish(entries);
  }

  /// Unpacks [package] and adds it, where [available]. Fails with an
  /// [IOException], leaving nothing behind, when its files cannot be
  /// written.
  Future<WebExtensionEntry> add(ExtensionPackage package) async {
    final folders = _folders;
    if (folders == null) {
      throw StateError('import is offered only where the library has a folder');
    }
    final manifest = package.manifest;
    final entry = WebExtensionEntry(
      id: WebExtensionId.mint(),
      name: manifest.name,
      version: manifest.version,
      permissions: manifest.permissions,
      hosts: manifest.hosts,
    );
    try {
      await folders.unpack(entry.id, files: package.files);
    } on IOException {
      await folders.delete(entry.id);
      rethrow;
    }
    final entries = [for (final i in _installed.value) i.entry, entry];
    _publish(entries);
    await _save(entries);
    LogTag.webExtension.debug('added ${entry.id}');
    return entry;
  }

  /// Drops [id] from the library and deletes its files. A site that had it
  /// switched on keeps the id, which names nothing any more.
  Future<void> remove(WebExtensionId id) async {
    final entries = [
      for (final i in _installed.value)
        if (i.entry.id != id) i.entry,
    ];
    _publish(entries);
    await _save(entries);
    try {
      await _folders?.delete(id);
    } on IOException catch (e) {
      LogTag.webExtension.info('$id stays on disk until the next launch: $e');
    }
    LogTag.webExtension.debug('removed $id');
  }

  void _publish(List<WebExtensionEntry> entries) {
    final folders = _folders;
    _installed.value = folders == null
        ? const []
        : List.unmodifiable([
            for (final entry in entries)
              (entry: entry, folder: folders.folderOf(entry.id)),
          ]);
  }

  Future<void> _save(List<WebExtensionEntry> entries) async {
    if (isDemoMode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, [
      for (final e in entries) jsonEncode(e.toJson()),
    ]);
  }

  static WebExtensionEntry? _decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    return WebExtensionEntry.fromJson(json);
  }

  @visibleForTesting
  void debugReset() {
    _folders = null;
    _installed.value = const [];
  }
}
