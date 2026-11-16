import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/setting_tile.dart';

/// What the Backup and archives screen asks App Settings to do. Each one runs
/// on the main page once settings has closed.
enum AppBackupAction { export, import, restoreArchive, closeAllArchives }

extension on AppBackupAction {
  IconData get icon => switch (this) {
    AppBackupAction.export => Icons.upload,
    AppBackupAction.import => Icons.download,
    AppBackupAction.restoreArchive => Icons.archive_outlined,
    AppBackupAction.closeAllArchives => Icons.lock_outline,
  };

  Localized title(AppLocalizations loc) => switch (this) {
    AppBackupAction.export => loc.appSettingsExportSettings,
    AppBackupAction.import => loc.appSettingsImportSettings,
    AppBackupAction.restoreArchive => loc.appSettingsRestoreArchive,
    AppBackupAction.closeAllArchives => loc.appSettingsCloseAllArchives,
  };

  Localized subtitle(AppLocalizations loc) => switch (this) {
    AppBackupAction.export => loc.appSettingsExportSettingsSubtitle,
    AppBackupAction.import => loc.appSettingsImportSettingsSubtitle,
    AppBackupAction.restoreArchive => loc.appSettingsRestoreArchiveSubtitle,
    AppBackupAction.closeAllArchives => loc.appSettingsCloseAllArchivesSubtitle,
  };
}

/// Settings export and import, and the passphrase-gated archives.
///
/// Holds no state: the row it was opened from closes settings and runs the
/// chosen action, so this screen only reports which one.
class AppBackupScreen extends StatefulWidget {
  const AppBackupScreen({
    super.key,
    this.offerRestoreArchive = false,
    this.offerCloseAllArchives = false,
    this.archives,
    this.onOpenSite,
  });

  final bool offerRestoreArchive;

  /// True only while an archive is open in this process. Its absence says
  /// nothing about whether any archive exists on disk (ARCH-001).
  final bool offerCloseAllArchives;
  final ArchiveController? archives;
  final Future<void> Function(WebViewModel)? onOpenSite;

  @override
  State<AppBackupScreen> createState() => _AppBackupScreenState();
}

class _AppBackupScreenState extends State<AppBackupScreen> {
  void _failed() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context).downloadButtonFailed),
    ));
  }

  Future<void> _close(ArchiveHandle handle) async {
    final bool closed;
    try {
      closed = await widget.archives!.close(handle);
    } on StateError {
      _failed();
      return;
    } on PlatformException {
      _failed();
      return;
    }
    if (!mounted) return;
    setState(() {});
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(closed ? loc.homeArchiveClosed : loc.homeArchiveFull),
      ),
    );
  }

  Future<void> _remove(ArchiveHandle handle) async {
    final loc = AppLocalizations.of(context);
    if (!await confirm(
      context,
      title: loc.archiveManagementRemove,
      body: loc.archiveManagementRemoveBody,
      confirmLabel: loc.commonRemove,
      destructive: true,
    )) {
      return;
    }
    try {
      await widget.archives!.removeKeepingSites(handle);
      if (mounted) setState(() {});
    } on StateError {
      _failed();
    } on PlatformException {
      _failed();
    }
  }

  Widget _archive(
    ArchiveHandle handle, {
    required int index,
    required AppLocalizations loc,
  }) {
    final sites = widget.archives!.sitesIn(handle);
    return ExpansionTile(
      key: ValueKey(handle),
      title: Text(loc.archiveManagementArchive(index + 1)),
      children: [
        for (final site in sites)
          ListTile(
            title: Text(site.getDisplayName()),
            subtitle: Text(site.initUrl),
            onTap: widget.onOpenSite == null
                ? null
                : () async {
                    Navigator.pop(context);
                    await widget.onOpenSite!(site);
                  },
            trailing: PopupMenuButton<String>(
              onSelected: (action) async {
                if (action == 'move') {
                  try {
                    await widget.archives!.moveOut(site);
                    if (mounted) setState(() {});
                  } on StateError {
                    _failed();
                  } on PlatformException {
                    _failed();
                  }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'move',
                  child: Text(loc.homeMoveOutOfArchive),
                ),
              ],
            ),
          ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: Text(loc.homeCloseArchive),
          onTap: () => _close(handle),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(loc.archiveManagementRemove),
          onTap: () => _remove(handle),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    // A second tap while the first choice pops would pop App Settings too.
    void choose(AppBackupAction action) {
      if (ModalRoute.isCurrentOf(context) == false) return;
      Navigator.pop(context, action);
    }

    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsBackupAndArchives)),
      body: ListView(
        children: [
          for (final action in [
            AppBackupAction.export,
            AppBackupAction.import,
            if (widget.archives == null && widget.offerRestoreArchive)
              AppBackupAction.restoreArchive,
            if (widget.archives?.anyOpen ?? widget.offerCloseAllArchives)
              AppBackupAction.closeAllArchives,
          ])
            SettingTile(
              leading: Icon(action.icon),
              title: action.title(loc),
              hint: null,
              subtitle: action.subtitle(loc),
              control: Trailing(
                null,
                onTap: () async {
                  if (action == AppBackupAction.closeAllArchives &&
                      widget.archives != null) {
                    final closed = await widget.archives!.closeAll();
                    if (!mounted) return;
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          closed ? loc.homeArchivesClosed : loc.homeArchiveFull,
                        ),
                      ),
                    );
                  } else {
                    choose(action);
                  }
                },
              ),
            ),
          if (widget.archives != null) ...[
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(loc.archiveManagementOpen),
              onTap: () async {
                await widget.archives!.promptRestore();
                if (mounted) setState(() {});
              },
            ),
            for (final (index, handle) in widget.archives!.openArchives.indexed)
              _archive(handle, index: index, loc: loc),
          ],
        ],
      ),
    );
  }
}
