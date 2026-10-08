import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
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

  String title(AppLocalizations loc) => switch (this) {
        AppBackupAction.export => loc.appSettingsExportSettings,
        AppBackupAction.import => loc.appSettingsImportSettings,
        AppBackupAction.restoreArchive => loc.appSettingsRestoreArchive,
        AppBackupAction.closeAllArchives => loc.appSettingsCloseAllArchives,
      };

  String subtitle(AppLocalizations loc) => switch (this) {
        AppBackupAction.export => loc.appSettingsExportSettingsSubtitle,
        AppBackupAction.import => loc.appSettingsImportSettingsSubtitle,
        AppBackupAction.restoreArchive =>
          loc.appSettingsRestoreArchiveSubtitle,
        AppBackupAction.closeAllArchives =>
          loc.appSettingsCloseAllArchivesSubtitle,
      };
}

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
          for (final action in [
            AppBackupAction.export,
            AppBackupAction.import,
            if (offerRestoreArchive) AppBackupAction.restoreArchive,
            if (offerCloseAllArchives) AppBackupAction.closeAllArchives,
          ])
            SettingTile(
              leading: Icon(action.icon),
              title: action.title(loc),
              hint: null,
              subtitle: action.subtitle(loc),
              control: Trailing(null, onTap: () => choose(action)),
            ),
        ],
      ),
    );
  }
}
