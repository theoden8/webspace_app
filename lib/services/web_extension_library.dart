/// The web extensions imported on this device (WEBEXT-002): each one's
/// entry, saved in SharedPreferences, its files, unpacked into a folder of
/// its own, and what WebKit reported reading them (WEBEXT-003). A backup
/// carries none of it (WEBEXT-011).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/host_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_backup.dart';

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

  /// The files in [id]'s folder, keyed by their path inside it.
  Future<Map<String, Uint8List>> read(WebExtensionId id);

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
  Future<Map<String, Uint8List>> read(WebExtensionId id) async {
    final folder = folderOf(id);
    return {
      for (final path in await hostListFilesUnder(folder))
        path: await hostReadFileBytes('$folder/$path'),
    };
  }

  @override
  Future<List<String>> names() => hostListDirectoryNames(root);
}

class WebExtensionLibrary {
  WebExtensionLibrary._();
  static final WebExtensionLibrary instance = WebExtensionLibrary._();

  static const _prefsKey = 'webExtensionLibrary';
  static const _directory = 'web_extensions';

  ExtensionFolders? _folders;
  ExtensionEngine _engine = const NativeExtensionEngine();
  final ValueNotifier<List<InstalledExtension>> _installed = ValueNotifier(
    const [],
  );
  final ValueNotifier<Map<WebExtensionId, ExtensionReport>> _reports =
      ValueNotifier(const {});

  /// The extensions a site may switch on, in import order. Empty where the
  /// host runs none, or where their folders could not be found.
  ValueListenable<List<InstalledExtension>> get installed => _installed;

  /// What WebKit reported reading each installed extension, once it has
  /// read it.
  ValueListenable<Map<WebExtensionId, ExtensionReport>> get reports => _reports;

  /// Whether an import can be unpacked here.
  bool get available => _folders != null;

  /// Reads the library and removes any folder no entry names: one left by
  /// an import cut short, a removal cut short, or demo mode. Then has WebKit
  /// read each extension, without holding up the launch.
  Future<void> initialize({
    @visibleForTesting ExtensionFolders? folders,
    @visibleForTesting ExtensionEngine? engine,
  }) async {
    if (folders == null && !hostRunsWebExtensions) return;
    if (engine != null) _engine = engine;
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
            await hostEntryPath(_directory, kind: StoreKind.data),
          );
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
    unawaited(_inspect(_installed.value));
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
      everySite: false,
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
    await _inspect([
      for (final i in _installed.value)
        if (i.entry.id == entry.id) i,
    ]);
    return entry;
  }

  /// Sets whether every site that sets no choice of its own runs [id]
  /// (WEBEXT-004).
  Future<void> setEverySite(WebExtensionId id, {required bool on}) async {
    final entries = [
      for (final i in _installed.value)
        i.entry.id == id ? i.entry.withEverySite(on: on) : i.entry,
    ];
    _publish(entries);
    await _save(entries);
  }

  /// Drops [id] from the library, stops it wherever it runs, and deletes
  /// what it stored on every site and its files. A site that had it switched
  /// on keeps the id, which names nothing any more.
  Future<void> remove(WebExtensionId id) async {
    final entries = [
      for (final i in _installed.value)
        if (i.entry.id != id) i.entry,
    ];
    _publish(entries);
    _reports.value = Map.unmodifiable({
      for (final MapEntry(:key, :value) in _reports.value.entries)
        if (key != id) key: value,
    });
    await _save(entries);
    await _engine.forget(id);
    try {
      await _folders?.delete(id);
    } on IOException catch (e) {
      LogTag.webExtension.info('$id stays on disk until the next launch: $e');
    }
    LogTag.webExtension.debug('removed $id');
  }

  /// The extensions [home] runs that have [page], by what WebKit reported,
  /// in import order (WEBEXT-008).
  List<WebExtensionEntry> offering(
    ExtensionPage page, {
    required ExtensionHome home,
  }) {
    final runs = {for (final load in home.plan.loads) load.id};
    return [
      for (final (:entry, folder: _) in _installed.value)
        if (runs.contains(entry.id))
          if (_reports.value[entry.id] case final report?)
            if (switch (page) {
              ExtensionPage.options => report.hasOptionsPage,
              ExtensionPage.action => report.hasAction,
            })
              entry,
    ];
  }

  /// Each way a backup can carry the library, with its size (WEBEXT-011).
  /// Fails with an [IOException] when a folder cannot be read.
  Future<ExtensionCarryOffer> carryOffer() async {
    final folders = _folders;
    if (folders == null) return offerExtensionCarry(const []);
    final library = [
      for (final (:entry, folder: _) in _installed.value)
        (entry: entry, files: await folders.read(entry.id)),
    ];
    return compute(offerExtensionCarry, library);
  }

  /// Each installed extension by the fingerprint of its files, which an
  /// imported backup's extensions are linked by (WEBEXT-011). Fails with an
  /// [IOException] when a folder cannot be read.
  Future<Map<String, WebExtensionId>> fingerprints() async {
    final folders = _folders;
    if (folders == null) return const {};
    return {
      for (final (:entry, folder: _) in _installed.value)
        extensionFingerprint(await folders.read(entry.id)): entry.id,
    };
  }

  /// Links [incoming], a backup's extensions, to the library by their
  /// fingerprints, and adds those it carries files of that the library lacks
  /// once [confirmAdd] accepts them (WEBEXT-011). Returns each linked or
  /// added extension's id here by its id in the backup, and how many of the
  /// backup's extensions it could neither link nor add.
  Future<({Map<WebExtensionId, WebExtensionId> links, int missing})>
  restoreFromBackup(
    BackupExtensions incoming, {
    required Future<bool> Function(List<ExtensionPackage> packages) confirmAdd,
  }) async {
    final all = {for (final e in incoming.extensions) e.id};
    final none = (
      links: const <WebExtensionId, WebExtensionId>{},
      missing: all.length,
    );
    if (!available) return none;
    final ExtensionRelinkPlan relink;
    try {
      relink = planExtensionRelink(incoming, library: await fingerprints());
    } on IOException catch (e) {
      LogTag.webExtension.info('backup not relinked: $e');
      return none;
    }
    final links = {...relink.linked};
    final readable = <(WebExtensionId, ExtensionPackage)>[];
    for (final carried in relink.toAdd) {
      if (await compute(readExtensionPackage, carried.package!)
          case final ExtensionPackage package) {
        readable.add((carried.id, package));
      }
    }
    if (readable.isNotEmpty &&
        await confirmAdd([for (final (_, package) in readable) package])) {
      for (final (id, package) in readable) {
        try {
          links[id] = (await add(package)).id;
        } on IOException catch (e) {
          LogTag.webExtension.info('$id not added from the backup: $e');
        }
      }
    }
    return (
      links: links,
      missing: all.where((id) => !links.containsKey(id)).length,
    );
  }

  /// Shows [page] of [extension] over the site [home] belongs to; false
  /// when it was not shown.
  Future<bool> open(
    ExtensionPage page, {
    required WebExtensionId extension,
    required ExtensionHome home,
  }) => _engine.openPage(page, extension: extension, home: home);

  Future<void> _inspect(List<InstalledExtension> installed) async {
    for (final (:entry, :folder) in installed) {
      final report = await _engine.inspect(folder);
      if (report == null) continue;
      if (!_installed.value.any((i) => i.entry.id == entry.id)) continue;
      if (report.problems.isNotEmpty) {
        LogTag.webExtension.info(
          '${entry.id}: WebKit reported ${report.problems.length} problems',
        );
      }
      _reports.value = Map.unmodifiable({..._reports.value, entry.id: report});
    }
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
    _engine = const NativeExtensionEngine();
    _installed.value = const [];
    _reports.value = const {};
  }
}
