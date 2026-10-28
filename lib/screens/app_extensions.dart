import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/app_distribution.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/app_extension_entry.dart';
import 'package:webspace/screens/extension_search.dart';
import 'package:webspace/services/file_dialog.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/services/web_extension_source_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/byte_size.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_source.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/extension_link_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/toast.dart';

/// The bytes of a file the user picks, or null when they pick none. Fails
/// with [FileDialogFailure] or an [IOException].
typedef PickPackage = Future<Uint8List?> Function();

/// Any file: a package is told from its bytes, and iOS offers no file type
/// for `.crx` or `.xpi`.
Future<Uint8List?> pickPackageFile() async {
  final file = await FileDialog.pickFile(withData: true);
  if (file == null) return null;
  return file.bytes ??
      switch (file.path) {
        final path? => await hostReadFileBytes(path),
        null => null,
      };
}

/// App Settings > Extensions (WEBEXT-002): the extensions imported on this
/// device, what WebKit reported reading each (WEBEXT-003), an import from a
/// file the user picks, and removal. Reached only while
/// [webExtensionsOffered].
class AppExtensionsScreen extends StatefulWidget {
  const AppExtensionsScreen({super.key, this.pick = pickPackageFile});

  final PickPackage pick;

  @override
  State<AppExtensionsScreen> createState() => _AppExtensionsScreenState();
}

class _AppExtensionsScreenState extends State<AppExtensionsScreen> {
  final _guard = ReentryGuard();
  bool _reading = false;

  WebExtensionLibrary get _library => WebExtensionLibrary.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_library.checkUpdates(now: DateTime.now()));
  }

  /// Adds an extension from a link to its listing or repository
  /// (WEBEXT-017).
  Future<void> _addFromLink() async {
    await _guard.run(() async {
      final source = await showDialog<ExtensionSource>(
        context: context,
        builder: (_) => const ExtensionLinkDialog(),
      );
      if (source == null || !mounted) return;
      await _addFrom(source);
    });
  }

  /// Adds an extension the user picks in a search of addons.mozilla.org,
  /// as from its link (WEBEXT-019).
  Future<void> _addFromSearch() async {
    await _guard.run(() async {
      final source = await Navigator.push<ExtensionSource>(
        context,
        MaterialPageRoute(builder: (_) => const ExtensionSearchScreen()),
      );
      if (source == null || !mounted) return;
      await _addFrom(source);
    });
  }

  /// Adds the extension [source] publishes: its latest release, the
  /// package the user picks where there are several, and the same summary
  /// as a file import (WEBEXT-017).
  Future<void> _addFrom(ExtensionSource source) async {
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _reading = true);
    try {
      final ReleaseFound release;
      switch (await _library.latest(source)) {
        case SourceFailed(:final reason):
          messenger.toast(loc.extensionsLinkUnreachable(reason));
          return;
        case SourceGot(value: ReleaseRefused(:final why)):
          messenger.toast(loc.extensionsLinkNoRelease(why.label(loc)));
          return;
        case SourceGot(value: final ReleaseFound found):
          release = found;
      }
      if (!mounted) return;
      setState(() => _reading = false);
      final candidate = release.candidates.length == 1
          ? release.candidates.single
          : await _pickCandidate(release);
      if (candidate == null || !mounted) return;
      setState(() => _reading = true);
      final ExtensionPackage package;
      switch (await _library.download(candidate)) {
        case SourceFailed(:final reason):
          messenger.toast(loc.extensionsLinkUnreachable(reason));
          return;
        case SourceGot(value: PackageRefused(:final why)):
          messenger.toast(loc.extensionsRefused(why.label(loc)));
          return;
        case SourceGot(value: final ExtensionPackage read):
          package = read;
      }
      if (!mounted) return;
      setState(() => _reading = false);
      if (!await _confirmAdd(package)) return;
      try {
        final entry = await _library.add(
          package,
          source: switch (source) {
            AmoSource() => source,
            GitHubSource(:final owner, :final repo) => GitHubSource(
              owner: owner,
              repo: repo,
              asset: assetPattern(candidate.name, version: release.version),
            ),
          },
        );
        messenger.toast(loc.extensionsAdded(entry.name));
      } on IOException catch (e) {
        messenger.toast(loc.extensionsImportFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// Which of [release]'s packages to add, offered in the engine's order.
  Future<PackageCandidate?> _pickCandidate(ReleaseFound release) {
    final loc = AppLocalizations.of(context);
    return showDialog<PackageCandidate>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(loc.extensionsPickPackage(release.version)),
        children: [
          for (final candidate in release.candidates)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(candidate.name),
              subtitle: switch (candidate.size) {
                final int size => Text(formatByteSize(size)),
                null => null,
              },
              onTap: () => Navigator.pop(dialog, candidate),
            ),
        ],
      ),
    );
  }

  Future<void> _import() async {
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final Uint8List? bytes;
      try {
        bytes = await widget.pick();
      } on FileDialogFailure catch (e) {
        messenger.toast(loc.extensionsImportFailed(e.message));
        return;
      } on IOException catch (e) {
        messenger.toast(loc.extensionsImportFailed('$e'));
        return;
      }
      if (bytes == null) return;
      final read = await _library.readPackage(bytes);
      if (!mounted) return;
      switch (read) {
        case PackageRefused(:final why):
          LogTag.webExtension.info('refused: $why');
          messenger.toast(loc.extensionsRefused(why.label(loc)));
        case final ExtensionPackage package:
          if (!await _confirmAdd(package)) return;
          try {
            final entry = await _library.add(package);
            messenger.toast(loc.extensionsAdded(entry.name));
          } on IOException catch (e) {
            messenger.toast(loc.extensionsImportFailed('$e'));
          }
      }
    });
  }

  /// What the user sees before anything is added (WEBEXT-002).
  Future<bool> _confirmAdd(ExtensionPackage package) {
    final loc = AppLocalizations.of(context);
    final manifest = package.manifest;
    final permissions = manifest.permissions.toList()..sort();
    final hosts = manifest.hosts.toList()..sort();
    return confirm(
      context,
      title: loc.extensionsAddTitle(manifest.name),
      body: [
        loc.extensionsVersion(manifest.version),
        if (manifest.description case final description?
            when description.isNotEmpty)
          description,
        permissions.isEmpty
            ? loc.extensionsAsksNothing
            : loc.extensionsAsks(permissions.join(', ')),
        hosts.isEmpty
            ? loc.extensionsReachesNothing
            : loc.extensionsReaches(hosts.join(', ')),
        loc.extensionsOnlyItsSite,
        if (manifest.background == ExtensionBackground.persistentPage)
          loc.extensionsAlwaysLoaded,
        if (package.signatureUnchecked) loc.extensionsSignatureUnchecked,
      ].join('\n\n'),
      confirmLabel: loc.commonAdd,
      destructive: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsExtensions)),
      body: ListenableBuilder(
        listenable: Listenable.merge([_library.installed, _library.reports]),
        builder: (context, _) => ListView(
          children: [
            SettingTile(
              leading: const Icon(Icons.file_open_outlined),
              title: loc.extensionsImport,
              hint: loc.extensionsImportHint,
              subtitle: loc.extensionsImportSubtitle,
              control: Trailing(
                const Icon(Icons.add),
                onTap: () => unawaited(_import()),
              ),
            ),
            SettingTile(
              leading: const Icon(Icons.link),
              title: loc.extensionsAddFromLink,
              hint: loc.extensionsAddFromLinkHint,
              subtitle: loc.extensionsAddFromLinkSubtitle,
              control: Trailing(
                const Icon(Icons.add),
                onTap: () => unawaited(_addFromLink()),
              ),
            ),
            if (hostDistribution == AppDistribution.direct) ...[
              SettingTile(
                leading: const Icon(Icons.search),
                title: loc.extensionsSearch,
                hint: loc.extensionsSearchHint,
                subtitle: loc.extensionsSearchSubtitle,
                control: Opens(() => unawaited(_addFromSearch())),
              ),
              SettingTile(
                leading: const Icon(Icons.system_update_alt),
                title: loc.extensionsAutoUpdate,
                hint: loc.extensionsAutoUpdateHint,
                control: const PrefToggle(AppPref.webExtensionsAutoUpdate),
              ),
            ],
            if (_reading)
              Semantics(
                label: loc.extensionsReading,
                child: const LinearProgressIndicator(),
              ),
            if (_library.installed.value.isNotEmpty)
              SettingsSection(loc.extensionsLibrary),
            for (final (:entry, folder: _) in _library.installed.value)
              _entryTile(entry, loc: loc),
          ],
        ),
      ),
    );
  }

  /// [entry] as the library lists it, with what WebKit reported reading it
  /// (WEBEXT-003), the count in its subtitle and each problem behind its
  /// hint, and whether every site runs it; it opens the entry's screen.
  Widget _entryTile(WebExtensionEntry entry, {required AppLocalizations loc}) {
    final problems =
        _library.reports.value[entry.id]?.problems ?? const <String>[];
    return SettingTile(
      leading: const Icon(Icons.extension_outlined),
      title: entry.name,
      hint: problems.isEmpty
          ? null
          : loc.extensionsProblemsHint(problems.join('\n\n')),
      subtitle: problems.isNotEmpty
          ? loc.extensionsVersionProblems(problems.length, entry.version)
          : entry.latest != null
          ? loc.extensionsVersionUpdate(entry.version, entry.latest!)
          : entry.everySite
          ? loc.extensionsVersionEverySite(entry.version)
          : loc.extensionsVersion(entry.version),
      missingData: problems.isNotEmpty,
      control: Opens(
        () => unawaited(
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ExtensionEntryScreen(id: entry.id),
            ),
          ),
        ),
      ),
    );
  }
}

extension PackageRefusalLabel on PackageRefusal {
  /// Why the file is not imported, in the refusal's own terms (WEBEXT-002).
  String label(AppLocalizations loc) => switch (this) {
    NotAPackage() => loc.extensionsRefusedNotAPackage,
    Truncated() ||
    BrokenArchive() ||
    CorruptEntry() => loc.extensionsRefusedDamaged,
    TooLarge() => loc.extensionsRefusedTooLarge,
    UnsupportedPackage() => loc.extensionsRefusedUnsupported,
    UnsafeEntry(:final name) => loc.extensionsRefusedUnsafeName(name),
    NoManifest() => loc.extensionsRefusedNoManifest,
    BadManifest(:final problem) => switch (problem) {
      ManifestProblem.manifestVersion => loc.extensionsRefusedManifestVersion,
      ManifestProblem.notJson ||
      ManifestProblem.notObject ||
      ManifestProblem.noName ||
      ManifestProblem.noVersion => loc.extensionsRefusedBadManifest,
    },
  };
}

extension ReleaseProblemLabel on ReleaseProblem {
  /// Why a source's latest release adds nothing (WEBEXT-017).
  String label(AppLocalizations loc) => switch (this) {
    ReleaseProblem.notJson => loc.extensionsReleaseNotJson,
    ReleaseProblem.noVersion => loc.extensionsReleaseNoVersion,
    ReleaseProblem.noPackage => loc.extensionsReleaseNoPackage,
  };
}
