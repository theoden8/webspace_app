import 'package:flutter/material.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/byte_size.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

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

  @override
  Future<bool> confirmRestoreScripts(List<HeldScript> held) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context).textTheme;
    return confirm(
      context,
      title: loc.homeImportHeldScriptsTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.homeImportHeldScriptsBody),
          for (final script in held) ...[
            const SizedBox(height: Spacing.md),
            Text(script.script.name, style: theme.titleSmall),
            Text(
              loc.homeImportHeldScriptsRunsOn(
                  script.sites.map((s) => s.getDisplayName()).join(', ')),
              style: theme.bodySmall,
            ),
          ],
        ],
      ),
      confirmLabel: loc.homeImportHeldScriptsTurnOn,
      cancelLabel: loc.homeImportHeldScriptsLeaveOff,
      destructive: false,
    );
  }

  @override
  Future<ExtensionCarry?> chooseExtensionCarry(ExtensionCarryOffer offer) {
    final loc = AppLocalizations.of(context);
    final choices = [
      (
        ExtensionCarry.leaveOut,
        loc.backupExtensionsLeaveOut,
        loc.backupExtensionsLeaveOutDetail,
      ),
      (
        ExtensionCarry.references,
        loc.backupExtensionsReferences,
        loc.backupExtensionsReferencesDetail(
          formatByteSize(offer.referencesBytes),
        ),
      ),
      (
        ExtensionCarry.files,
        loc.backupExtensionsFiles,
        loc.backupExtensionsFilesDetail(formatByteSize(offer.filesBytes)),
      ),
    ];
    return showDialog<ExtensionCarry>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(loc.backupExtensionsTitle),
        contentPadding: const EdgeInsets.only(top: Spacing.md),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
                child: Text(loc.backupExtensionsBody(offer.count)),
              ),
              const SizedBox(height: Spacing.sm),
              for (final (carry, title, detail) in choices)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Spacing.xl,
                  ),
                  title: Text(title),
                  subtitle: Text(detail),
                  onTap: () => Navigator.pop(dialog, carry),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(loc.commonCancel),
          ),
        ],
      ),
    );
  }

  @override
  Future<bool> confirmAddExtensions(List<ExtensionPackage> packages) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context).textTheme;
    return confirm(
      context,
      title: loc.backupExtensionsAddTitle(packages.length),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.backupExtensionsAddBody),
          for (final ExtensionPackage(:manifest, :signatureUnchecked)
              in packages) ...[
            const SizedBox(height: Spacing.md),
            Text(manifest.name, style: theme.titleSmall),
            Text(
              [
                loc.extensionsVersion(manifest.version),
                manifest.permissions.isEmpty
                    ? loc.extensionsAsksNothing
                    : loc.extensionsAsks(
                        (manifest.permissions.toList()..sort()).join(', ')),
                manifest.hosts.isEmpty
                    ? loc.extensionsReachesNothing
                    : loc.extensionsReaches(
                        (manifest.hosts.toList()..sort()).join(', ')),
                if (signatureUnchecked) loc.extensionsSignatureUnchecked,
              ].join('\n'),
              style: theme.bodySmall,
            ),
          ],
        ],
      ),
      confirmLabel: loc.commonAdd,
      destructive: false,
    );
  }
}
