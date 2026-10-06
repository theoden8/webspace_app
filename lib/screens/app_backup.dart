import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';

/// What the Backup and archives screen asks App Settings to do. Each one runs
/// on the main page once settings has closed, as it did from the single list.
enum AppBackupAction { export, import, restoreArchive, closeAllArchives }

/// Settings export and import, and the passphrase-gated archives.
///
/// Holds no state: the row it was opened from closes settings and runs the
/// chosen action, so this screen only reports which one.
class AppBackupScreen extends StatelessWidget {
  const AppBackupScreen({
    super.key,
    this.offerRestoreArchive = false,
    this.offerCloseAllArchives = false,
  });

  final bool offerRestoreArchive;

  /// True only while an archive is open in this process. Its absence says
  /// nothing about whether any archive exists on disk (ARCH-001).
  final bool offerCloseAllArchives;

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
          ListTile(
            leading: const Icon(Icons.upload),
            title: Text(loc.appSettingsExportSettings),
            subtitle: Text(loc.appSettingsExportSettingsSubtitle),
            onTap: () => choose(AppBackupAction.export),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(loc.appSettingsImportSettings),
            subtitle: Text(loc.appSettingsImportSettingsSubtitle),
            onTap: () => choose(AppBackupAction.import),
          ),
          if (offerRestoreArchive)
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(loc.appSettingsRestoreArchive),
              subtitle: Text(loc.appSettingsRestoreArchiveSubtitle),
              onTap: () => choose(AppBackupAction.restoreArchive),
            ),
          if (offerCloseAllArchives)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(loc.appSettingsCloseAllArchives),
              subtitle: Text(loc.appSettingsCloseAllArchivesSubtitle),
              onTap: () => choose(AppBackupAction.closeAllArchives),
            ),
        ],
      ),
    );
  }
}
