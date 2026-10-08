import 'package:flutter/material.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';

/// [BackupPrompts] as a file picker and dialogs over the page that owns
/// [context].
class DialogBackupPrompts implements BackupPrompts {
  const DialogBackupPrompts(this.context);

  final BuildContext context;

  @override
  Future<SettingsBackup?> pick() => SettingsBackupService.pickAndImport(context);

  @override
  Future<void> save(SettingsBackup backup) =>
      SettingsBackupService.exportAndSave(context, backup: backup);

  @override
  Future<bool> confirmImport(SettingsBackup backup) async {
    final sitesCount = backup.sites.length;
    final webspacesCount = backup.webspaces.length;
    final exportDate = backup.exportedAt.toLocal().toString().split('.')[0];

    final loc = AppLocalizations.of(context);
    final exportedLabel = loc.homeImportExportedLabel(exportDate);
    // State the backup installs that acts on its own once restored: the
    // app-wide proxy captures every DEFAULT site including webview traffic,
    // and a user script runs at document start with full page privileges.
    // Neither is visible in a site list, so the dialog has to name them.
    final incomingGlobalProxy = backupGlobalProxyAddress(backup);
    final incomingScriptCount = backupUserScriptCount(backup);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeImportSettingsTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.homeImportSettingsConfirm(sitesCount, webspacesCount)),
              SizedBox(height: 12),
              Text(
                exportedLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (incomingGlobalProxy != null) ...[
                SizedBox(height: 12),
                Text(loc.homeImportGlobalProxyWarning(incomingGlobalProxy)),
              ],
              if (incomingScriptCount > 0) ...[
                SizedBox(height: 12),
                Text(loc.homeImportUserScriptsWarning(incomingScriptCount)),
              ],
              SizedBox(height: 16),
              Text(
                loc.homeImportSettingsSessionsNote,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.homeImportAction),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}
