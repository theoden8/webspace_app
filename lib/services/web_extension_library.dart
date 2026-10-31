/// The web extensions imported on this device (WEBEXT-002): each one's
/// entry, saved in SharedPreferences, its files, unpacked into a folder of
/// its own, and what WebKit reported reading them (WEBEXT-003). A backup
/// carries none of it (WEBEXT-011).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/app_distribution.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/host_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_native.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_search_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/settings/web_extension_source.dart';

/// Whether extensions are offered here now (WEBEXT-001): on a host that runs
/// them, with developer mode and the Web extensions switch on. Every
/// webview's plan and every Extensions row reads it.
bool get webExtensionsOffered =>
    hostRunsWebExtensions &&
    ExperimentalFeaturesService.instance.isEnabled(
      ExperimentalFeature.webExtensions,
    );

/// Whether this build carries the search of addons.mozilla.org at all
/// (WEBEXT-019): only one made with
/// `--dart-define=WEBSPACE_EXTENSION_SEARCH=true`, which no App Store build
/// is. Without it the compiler leaves the search bar, its screen and its
/// queries out of the binary.
const bool extensionSearchBuilt = bool.fromEnvironment(
  'WEBSPACE_EXTENSION_SEARCH',
);

/// Test seam: a debug build that carries the search without the define.
/// A release build never reads it, so it cannot keep the search in one.
@visibleForTesting
bool? debugExtensionSearchBuilt;

bool get _searchBuilt =>
    extensionSearchBuilt ||
    (kDebugMode && (debugExtensionSearchBuilt ?? false));

/// Whether the Experimental group offers the Extension search switch: in a
/// build that carries the search, on a host that runs extensions, installed
/// from outside the App Store.
bool get extensionSearchSwitchOffered =>
    _searchBuilt &&
    hostRunsWebExtensions &&
    hostDistribution == AppDistribution.direct;

/// Whether the search of addons.mozilla.org is offered (WEBEXT-019): where
/// its switch is offered and on, and extensions are.
bool get extensionSearchOffered =>
    extensionSearchSwitchOffered &&
    webExtensionsOffered &&
    ExperimentalFeaturesService.instance.isEnabled(
      ExperimentalFeature.extensionSearch,
    );

/// What reading from an extension's source brought back: [value], or why
/// nothing could be read (WEBEXT-017).
sealed class SourceFetch<T> {
  const SourceFetch();
}

final class SourceGot<T> extends SourceFetch<T> {
  const SourceGot(this.value);
  final T value;
}

final class SourceFailed<T> extends SourceFetch<T> {
  const SourceFailed(this.reason);

  /// The transport's or the app-wide proxy's words.
  final String reason;
}

/// What getting an extension's update ready came to (WEBEXT-018).
sealed class UpdatePrepared {
  const UpdatePrepared();
}

/// Downloaded and read, with what it asks for beyond the installed version.
final class UpdateReady extends UpdatePrepared {
  const UpdateReady({required this.package, required this.asks});
  final ExtensionPackage package;
  final UpdateAsks asks;
}

/// The source or the package could not be reached.
final class UpdateUnreachable extends UpdatePrepared {
  const UpdateUnreachable(this.reason);
  final String reason;
}

/// The source answered with no release to install.
final class UpdateNoRelease extends UpdatePrepared {
  const UpdateNoRelease(this.why);
  final ReleaseProblem why;
}

/// The downloaded file is not a package WEBEXT-013 reads.
final class UpdateNotAPackage extends UpdatePrepared {
  const UpdateNotAPackage(this.why);
  final PackageRefusal why;
}

/// Why the sources are read (WEBEXT-018): the user asked, or the daily
/// check, which reads nothing until the user switches it on.
enum CheckReason {
  asked,
  daily;

  /// Whether a check for this reason reads [entry]'s source at [now].
  bool reads(WebExtensionEntry entry, {required DateTime now}) =>
      switch (this) {
        asked => true,
        daily =>
          AppPref.webExtensionsCheckUpdates.value &&
              checkDue(lastChecked: entry.checkedAt, now: now),
      };
}

/// What a check found: how many entries have a newer version, and how many
/// sources could not be read.
typedef UpdatesFound = ({int updates, int unreachable});

/// [readExtensionPackage], run where it does not hold up the frame.
typedef ReadPackage = Future<PackageRead> Function(Uint8List bytes);

Future<PackageRead> readPackageApart(Uint8List bytes) =>
    compute(readExtensionPackage, bytes);

/// A GET through the app-wide proxy, of at most [maxBytes].
typedef ExtensionFetch =
    Future<AppProxyFetch> Function(Uri url, {required int maxBytes});

Future<AppProxyFetch> _fetchViaAppProxy(Uri url, {required int maxBytes}) =>
    fetchViaAppProxy(
      url,
      tag: LogTag.webExtension,
      timeout: const IdleTimeout(Duration(seconds: 60)),
      maxBytes: maxBytes,
      headers: const {'Accept': 'application/json, */*'},
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

  /// Puts [files] in place of [id]'s folder, whole or not at all.
  Future<void> replace(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  });

  /// The files in [id]'s folder, keyed by their path inside it.
  Future<Map<String, Uint8List>> read(WebExtensionId id);

  /// The names of the folders present.
  Future<List<String>> names();
}

/// A folder an update is unpacked into before it takes the installed one's
/// place. One an update cut short left is cleared by the next update.
const _stagingPrefix = '.staging-';

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

  /// Unpacked beside the folder first, so a write cut short leaves the
  /// installed files as they were.
  @override
  Future<void> replace(
    WebExtensionId id, {
    required Map<String, Uint8List> files,
  }) async {
    final staging = '$root/$_stagingPrefix$id';
    await hostDeleteDirectory(staging);
    for (final MapEntry(key: path, value: bytes) in files.entries) {
      final slash = path.lastIndexOf('/');
      await hostEnsureDirectory(
        slash < 0 ? staging : '$staging/${path.substring(0, slash)}',
      );
      await hostWriteFileBytes('$staging/$path', bytes: bytes);
    }
    await hostDeleteDirectory(folderOf(id));
    await hostRenameDirectory(staging, to: folderOf(id));
  }

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
  ExtensionFetch _fetch = _fetchViaAppProxy;
  ReadPackage _read = readPackageApart;
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
  /// an import cut short, a removal cut short, or demo mode. A library not
  /// read whole may name any folder, so then none is removed. Then has
  /// WebKit read each extension, without holding up the launch.
  Future<void> initialize({
    @visibleForTesting ExtensionFolders? folders,
    @visibleForTesting ExtensionEngine? engine,
    @visibleForTesting ExtensionFetch? fetch,
    @visibleForTesting ReadPackage? read,
  }) async {
    if (folders == null && !hostRunsWebExtensions) return;
    if (engine != null) _engine = engine;
    if (fetch != null) _fetch = fetch;
    if (read != null) _read = read;
    final prefs = await SharedPreferences.getInstance();
    final saved = readPrefStrings(prefs, key: _prefsKey);
    final entries = [
      for (final raw in saved ?? const <String>[]) ?_decode(raw),
    ];
    final readWhole = saved == null
        ? !prefs.containsKey(_prefsKey)
        : entries.length == saved.length;
    try {
      final found =
          folders ??
          _HostExtensionFolders(
            await hostEntryPath(_directory, kind: StoreKind.data),
          );
      final present = await found.names();
      if (readWhole) {
        final named = {for (final e in entries) e.id as String};
        for (final name in present) {
          final id = WebExtensionId.parse(name);
          if (id != null && !named.contains(id)) await found.delete(id);
        }
      } else {
        LogTag.webExtension.warning(
          'library not read whole; kept ${present.length} folders',
        );
      }
      for (final e in entries) {
        if (!present.contains(e.id)) {
          LogTag.webExtension.warning('${e.id}: its folder is gone');
        }
      }
      _folders = found;
    } on IOException catch (e) {
      LogTag.webExtension.info('library unavailable: $e');
      return;
    }
    _publish(entries);
    unawaited(_inspect(_installed.value));
    if (webExtensionsOffered) {
      unawaited(checkUpdates(now: DateTime.now(), because: CheckReason.daily));
    }
  }

  /// Unpacks [package] and adds it, where [available], keeping the [source]
  /// it came from (WEBEXT-017). Fails with an [IOException], leaving
  /// nothing behind, when its files cannot be written.
  Future<WebExtensionEntry> add(
    ExtensionPackage package, {
    ExtensionSource? source,
  }) async {
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
      source: source,
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
    if (_entryOf(id) case final entry?) {
      await _replaceEntry(entry.withEverySite(on: on));
    }
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

  /// Whether WebKit loads [id] on this device, as it reported reading it;
  /// one not read yet is taken to load (WEBEXT-003).
  bool loadsHere(WebExtensionId id) => _reports.value[id]?.loadsHere ?? true;

  /// The extensions a site may attach: those WebKit loads on this device.
  List<InstalledExtension> get loadable => [
    for (final installed in _installed.value)
      if (loadsHere(installed.entry.id)) installed,
  ];

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

  /// [bytes], a package the user picked, read as WEBEXT-013 says.
  Future<PackageRead> readPackage(Uint8List bytes) => _read(bytes);

  /// [source]'s latest release, read without downloading it (WEBEXT-017).
  Future<SourceFetch<ReleaseRead>> latest(ExtensionSource source) async {
    switch (await _fetch(releaseQuery(source), maxBytes: _releaseBytes)) {
      case FetchRefused(:final reason) || FetchFailed(:final reason):
        return SourceFailed(reason);
      case Fetched(:final response):
        final Object? json;
        try {
          json = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          return SourceGot(readRelease(source, json: null));
        }
        return SourceGot(readRelease(source, json: json));
    }
  }

  static const _releaseBytes = 4 << 20;

  /// [candidate] downloaded and read as WEBEXT-013 says.
  Future<SourceFetch<PackageRead>> download(PackageCandidate candidate) async {
    switch (await _fetch(candidate.url, maxBytes: PackageLimits.packageBytes)) {
      case FetchRefused(:final reason) || FetchFailed(:final reason):
        return SourceFailed(reason);
      case Fetched(:final response):
        return SourceGot(await _read(response.bodyBytes));
    }
  }

  /// Reads the source of each extension added from a link that a check
  /// [because] reads, and marks those with a newer release (WEBEXT-018). A
  /// source that cannot be reached is read again next time.
  Future<UpdatesFound> checkUpdates({
    required DateTime now,
    required CheckReason because,
  }) async {
    var unreachable = 0;
    for (final (:entry, folder: _) in _installed.value) {
      final source = entry.source;
      if (source == null || !because.reads(entry, now: now)) continue;
      final SourceFetch<ReleaseRead> read = await latest(source);
      final checked = switch (read) {
        SourceFailed() => null,
        SourceGot(value: final release) => switch (checkUpdate(
          installedVersion: entry.version,
          release: release,
        )) {
          UpdateAvailable(:final version) => entry.withCheck(
            at: now,
            latest: version,
          ),
          UpToDate() => entry.withCheck(at: now, latest: null),
          CheckFailed() => entry.withCheck(at: now, latest: entry.latest),
        },
      };
      if (checked == null) {
        unreachable++;
        continue;
      }
      await _replaceEntry(checked);
      if (checked.latest != null && installsWithoutAsking) {
        await _installQuietly(checked.id);
      }
    }
    return (
      updates: _installed.value.where((e) => e.entry.latest != null).length,
      unreachable: unreachable,
    );
  }

  /// Whether an update that asks for nothing new installs as soon as a
  /// check finds it: only outside the App Store, where the user switched it
  /// on (WEBEXT-019).
  bool get installsWithoutAsking =>
      hostDistribution == AppDistribution.direct &&
      AppPref.webExtensionsAutoUpdate.value;

  Future<void> _installQuietly(WebExtensionId id) async {
    switch (await prepareUpdate(id)) {
      case UpdateReady(:final package, asks: AsksNothingNew()):
        try {
          await install(id, package: package);
        } on IOException catch (e) {
          LogTag.webExtension.info('$id stays at its version: $e');
        }
      case UpdateReady(asks: AsksMore()) ||
          UpdateUnreachable() ||
          UpdateNoRelease() ||
          UpdateNotAPackage():
        LogTag.webExtension.debug('$id waits for the user to update');
    }
  }

  /// A page of addons.mozilla.org's search for [text] (WEBEXT-019).
  Future<SourceFetch<SearchRead>> search(
    String text, {
    required bool recommendedOnly,
    required int page,
  }) async {
    assert(extensionSearchOffered, 'search runs only where it is offered');
    final query = amoSearchQuery(
      text,
      recommendedOnly: recommendedOnly,
      page: page,
    );
    switch (await _fetch(query, maxBytes: _releaseBytes)) {
      case FetchRefused(:final reason) || FetchFailed(:final reason):
        return SourceFailed(reason);
      case Fetched(:final response):
        try {
          return SourceGot(
            readAmoSearch(jsonDecode(utf8.decode(response.bodyBytes))),
          );
        } on FormatException {
          return SourceGot(readAmoSearch(null));
        }
    }
  }

  /// [id]'s update downloaded and read, with what it asks for beyond the
  /// installed version, ready for [install] once the user accepts any of
  /// that (WEBEXT-018).
  Future<UpdatePrepared> prepareUpdate(WebExtensionId id) async {
    final entry = _entryOf(id);
    final source = entry?.source;
    assert(source != null, 'only an extension with a source updates');
    if (entry == null || source == null) {
      return const UpdateNoRelease(ReleaseProblem.noPackage);
    }
    final PackageCandidate candidate;
    switch (await latest(source)) {
      case SourceFailed(:final reason):
        return UpdateUnreachable(reason);
      case SourceGot(value: ReleaseRefused(:final why)):
        return UpdateNoRelease(why);
      case SourceGot(value: ReleaseFound(:final candidates)):
        candidate = candidates.first;
    }
    return switch (await download(candidate)) {
      SourceFailed(:final reason) => UpdateUnreachable(reason),
      SourceGot(value: PackageRefused(:final why)) => UpdateNotAPackage(why),
      SourceGot(value: final ExtensionPackage package) => UpdateReady(
        package: package,
        asks: updateAsks(installed: entry, update: package.manifest),
      ),
    };
  }

  /// Puts [package] in place of [id]'s files, keeping its id, so the sites
  /// that run it keep it and its data (WEBEXT-018). Fails with an
  /// [IOException], leaving the installed files as they were, when its
  /// files cannot be written.
  Future<WebExtensionEntry> install(
    WebExtensionId id, {
    required ExtensionPackage package,
  }) async {
    final folders = _folders;
    final entry = _entryOf(id);
    if (folders == null || entry == null) {
      throw StateError('an update installs over an installed extension');
    }
    await folders.replace(id, files: package.files);
    final manifest = package.manifest;
    final updated = entry.updatedTo(
      name: manifest.name,
      version: manifest.version,
      permissions: manifest.permissions,
      hosts: manifest.hosts,
    );
    await _replaceEntry(updated);
    await _inspect([
      for (final i in _installed.value)
        if (i.entry.id == id) i,
    ]);
    LogTag.webExtension.debug('updated $id');
    return updated;
  }

  WebExtensionEntry? _entryOf(WebExtensionId id) => [
    for (final (:entry, folder: _) in _installed.value)
      if (entry.id == id) entry,
  ].firstOrNull;

  Future<void> _replaceEntry(WebExtensionEntry replacement) async {
    if (_entryOf(replacement.id) == null) return;
    final entries = [
      for (final (:entry, folder: _) in _installed.value)
        entry.id == replacement.id ? replacement : entry,
    ];
    _publish(entries);
    await _save(entries);
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
      if (await _read(carried.package!) case final ExtensionPackage package) {
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
    _fetch = _fetchViaAppProxy;
    _read = readPackageApart;
    _installed.value = const [];
    _reports.value = const {};
  }
}
