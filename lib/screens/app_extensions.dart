import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/file_dialog.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/toast.dart';

/// The bytes of a file the user picks, or null when they pick none. Fails
/// with [FileDialogFailure] or an [IOException].
typedef PickPackage = Future<Uint8List?> Function();

/// [readExtensionPackage], run where it does not hold up the frame.
typedef ReadPackage = Future<PackageRead> Function(Uint8List bytes);

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

Future<PackageRead> readPackageApart(Uint8List bytes) =>
    compute(readExtensionPackage, bytes);

/// App Settings > Extensions (WEBEXT-002): the extensions imported on this
/// device, what WebKit reported reading each (WEBEXT-003), an import from a
/// file the user picks, and removal. Reached only while
/// [webExtensionsOffered].
class AppExtensionsScreen extends StatefulWidget {
  const AppExtensionsScreen({
    super.key,
    this.pick = pickPackageFile,
    this.read = readPackageApart,
  });

  final PickPackage pick;
  final ReadPackage read;

  @override
  State<AppExtensionsScreen> createState() => _AppExtensionsScreenState();
}

class _AppExtensionsScreenState extends State<AppExtensionsScreen> {
  final _guard = ReentryGuard();

  WebExtensionLibrary get _library => WebExtensionLibrary.instance;

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
      final read = await widget.read(bytes);
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

  Future<void> _remove(WebExtensionEntry entry) async {
    await _guard.run(() async {
      final loc = AppLocalizations.of(context);
      final messenger = ScaffoldMessenger.of(context);
      if (!await confirm(
        context,
        title: loc.extensionsRemoveTitle(entry.name),
        body: loc.extensionsRemoveBody,
        confirmLabel: loc.commonRemove,
        destructive: true,
      )) {
        return;
      }
      await _library.remove(entry.id);
      messenger.toast(loc.extensionsRemoved(entry.name));
    });
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
  /// (WEBEXT-003): the count in its subtitle, each problem behind its hint.
  Widget _entryTile(WebExtensionEntry entry, {required AppLocalizations loc}) {
    final problems =
        _library.reports.value[entry.id]?.problems ?? const <String>[];
    return SettingTile(
      leading: const Icon(Icons.extension_outlined),
      title: entry.name,
      hint: problems.isEmpty
          ? null
          : loc.extensionsProblemsHint(problems.join('\n\n')),
      subtitle: problems.isEmpty
          ? loc.extensionsVersion(entry.version)
          : loc.extensionsVersionProblems(problems.length, entry.version),
      missingData: problems.isNotEmpty,
      control: Trailing(
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: loc.commonRemove,
          onPressed: () => unawaited(_remove(entry)),
        ),
      ),
    );
  }
}

extension on PackageRefusal {
  /// Why the file is not imported, in the refusal's own terms (WEBEXT-002).
  String label(AppLocalizations loc) => switch (this) {
    NotAPackage() => loc.extensionsRefusedNotAPackage,
    Truncated() || BrokenArchive() || CorruptEntry() =>
      loc.extensionsRefusedDamaged,
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
