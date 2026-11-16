import 'package:flutter/material.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/byte_size.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/web_view_model.dart';

/// [BackupPrompts] as a file picker and dialogs over the page that owns
/// [context].
class DialogBackupPrompts implements BackupPrompts {
  const DialogBackupPrompts(this.context);

  final BuildContext context;

  @override
  Future<BackupExportChoices?> configureExport(
    List<WebViewModel> sites, {
    required ExtensionCarryOffer? extensions,
    bool siteOnly = false,
  }) {
    final loc = AppLocalizations.of(context);
    final selected = {for (final site in sites) site.siteId.toString()};
    final scriptSites = {for (final site in sites) site.siteId.toString()};
    final cookieSites = {for (final site in sites) site.siteId.toString()};
    final extensionSites = {for (final site in sites) site.siteId.toString()};
    var appSettings = !siteOnly;
    final appPrefKeys = {for (final pref in AppPref.values) pref.key};
    var globalScripts = !siteOnly;
    var carry = ExtensionCarry.files;
    var section = 0; // Summary, sites, app settings, extensions.
    return showDialog<BackupExportChoices>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) {
          return PopScope(
            canPop: section == 0,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) refresh(() => section = 0);
            },
            child: Dialog.fullscreen(
              child: Scaffold(
                appBar: AppBar(
                  leading: section == 0
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => refresh(() => section = 0),
                        ),
                  title: Text(switch (section) {
                    1 => loc.backupAllSites,
                    2 => loc.backupChooseAppSettings,
                    3 => loc.backupExtensionsTitle,
                    _ => loc.backupConfigureTitle,
                  }),
                  actions: section == 0
                      ? [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: Text(loc.commonCancel),
                          ),
                        ]
                      : null,
                ),
                body: ListView(
                  children: [
                    if (section == 0) ...[
                      ListTile(
                        title: Text(loc.backupAllSites),
                        subtitle: Text('${selected.length} / ${sites.length}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => refresh(() => section = 1),
                      ),
                      ListTile(
                        title: Text(loc.backupAppSettings),
                        subtitle: Text(
                          '${appSettings ? appPrefKeys.length : 0} / ${AppPref.values.length}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => refresh(() => section = 2),
                      ),
                      CheckboxListTile(
                        title: Text(loc.backupGlobalScripts),
                        value: globalScripts,
                        onChanged: (v) =>
                            refresh(() => globalScripts = v ?? false),
                      ),
                      if (extensions != null)
                        ListTile(
                          title: Text(loc.backupExtensionsTitle),
                          subtitle: Text(switch (carry) {
                            ExtensionCarry.leaveOut =>
                              loc.backupExtensionsLeaveOut,
                            ExtensionCarry.references =>
                              loc.backupExtensionsReferences,
                            ExtensionCarry.files => loc.backupExtensionsFiles,
                          }),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => refresh(() => section = 3),
                        ),
                    ],
                    if (section == 1) ...[
                      CheckboxListTile(
                        title: Text(loc.backupAllSites),
                        subtitle: Text(loc.backupAllSitesDetail),
                        value:
                            selected.length == sites.length && sites.isNotEmpty,
                        onChanged: (value) => refresh(() {
                          selected.clear();
                          if (value == true) {
                            selected.addAll(
                              sites.map((s) => s.siteId.toString()),
                            );
                          }
                        }),
                      ),
                      for (final site in sites)
                        ExpansionTile(
                          leading: Checkbox(
                            value: selected.contains(site.siteId.toString()),
                            onChanged: (value) => refresh(() {
                              if (value == true) {
                                selected.add(site.siteId.toString());
                              } else {
                                selected.remove(site.siteId.toString());
                              }
                            }),
                          ),
                          title: Text(site.getDisplayName()),
                          children: selected.contains(site.siteId.toString())
                              ? [
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteScripts),
                                    value: scriptSites.contains(
                                      site.siteId.toString(),
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        scriptSites.add(site.siteId.toString());
                                      } else {
                                        scriptSites.remove(
                                          site.siteId.toString(),
                                        );
                                      }
                                    }),
                                  ),
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteCookies),
                                    value: cookieSites.contains(
                                      site.siteId.toString(),
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        cookieSites.add(site.siteId.toString());
                                      } else {
                                        cookieSites.remove(
                                          site.siteId.toString(),
                                        );
                                      }
                                    }),
                                  ),
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteExtensions),
                                    value: extensionSites.contains(
                                      site.siteId.toString(),
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        extensionSites.add(
                                          site.siteId.toString(),
                                        );
                                      } else {
                                        extensionSites.remove(
                                          site.siteId.toString(),
                                        );
                                      }
                                    }),
                                  ),
                                ]
                              : const [],
                        ),
                    ],
                    if (section == 2) ...[
                      CheckboxListTile(
                        title: Text(loc.backupAppSettings),
                        value: appSettings,
                        onChanged: (v) =>
                            refresh(() => appSettings = v ?? false),
                      ),
                      if (appSettings) ...[
                        for (final pref in AppPref.values)
                          CheckboxListTile(
                            title: Text(
                              pref.key
                                  .replaceAllMapped(
                                    RegExp(r'(?<=[a-z])(?=[A-Z])'),
                                    (match) => ' ',
                                  )
                                  .replaceFirstMapped(
                                    RegExp(r'^.'),
                                    (match) => match[0]!.toUpperCase(),
                                  ),
                            ),
                            value: appPrefKeys.contains(pref.key),
                            onChanged: (v) => refresh(() {
                              if (v == true) {
                                appPrefKeys.add(pref.key);
                              } else {
                                appPrefKeys.remove(pref.key);
                              }
                            }),
                          ),
                      ],
                    ],
                    if (section == 3 && extensions != null) ...[
                      ListTile(
                        title: Text(loc.backupExtensionsLeaveOut),
                        leading: Icon(
                          carry == ExtensionCarry.leaveOut
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: () =>
                            refresh(() => carry = ExtensionCarry.leaveOut),
                      ),
                      ListTile(
                        title: Text(loc.backupExtensionsReferences),
                        subtitle: Text(
                          formatByteSize(extensions.referencesBytes),
                        ),
                        leading: Icon(
                          carry == ExtensionCarry.references
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: () =>
                            refresh(() => carry = ExtensionCarry.references),
                      ),
                      ListTile(
                        title: Text(loc.backupExtensionsFiles),
                        subtitle: Text(formatByteSize(extensions.filesBytes)),
                        leading: Icon(
                          carry == ExtensionCarry.files
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: () =>
                            refresh(() => carry = ExtensionCarry.files),
                      ),
                    ],
                  ],
                ),
                bottomNavigationBar: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: FilledButton(
                      onPressed: section != 0
                          ? () => refresh(() => section = 0)
                          : () => Navigator.pop(
                              dialog,
                              BackupExportChoices(
                                siteIds: selected,
                                siteScriptIds: scriptSites,
                                siteCookieIds: cookieSites,
                                siteExtensionIds: extensionSites,
                                appSettings: appSettings,
                                appPrefKeys: appPrefKeys,
                                siteScripts: true,
                                globalScripts: globalScripts,
                                extensionCarry: carry,
                              ),
                            ),
                      child: Text(
                        section == 0 ? loc.backupCreateAction : loc.commonDone,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Future<BackupRestoreChoices?> reviewImport(SettingsBackup backup) {
    final loc = AppLocalizations.of(context);
    var sites = backup.includesSites;
    var appSettings = backup.includesAppSettings;
    var globalScripts = backup.globalUserScripts != null;
    var scripts = false;
    var extensions = backup.webExtensions != null;
    return showDialog<BackupRestoreChoices>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: Text(loc.backupRestoreTitle),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(loc.commonCancel),
                ),
              ],
            ),
            body: ListView(
              children: [
                ListTile(
                  title: Text(
                    loc.homeImportExportedLabel(
                      backup.exportedAt.toLocal().toString().split('.').first,
                    ),
                  ),
                ),
                CheckboxListTile(
                  title: Text(loc.backupAllSites),
                  subtitle: Text('${backup.sites.length}'),
                  value: sites,
                  onChanged: backup.includesSites
                      ? (v) => refresh(() => sites = v ?? false)
                      : null,
                ),
                CheckboxListTile(
                  title: Text(loc.backupAppSettings),
                  value: appSettings,
                  onChanged: backup.includesAppSettings
                      ? (v) => refresh(() => appSettings = v ?? false)
                      : null,
                ),
                if (backup.globalUserScripts != null)
                  CheckboxListTile(
                    title: Text(loc.backupGlobalScripts),
                    value: globalScripts,
                    onChanged: (v) => refresh(() => globalScripts = v ?? false),
                  ),
                if (appSettings)
                  if (backupGlobalProxyAddress(backup) case final proxy?)
                    ListTile(
                      title: Text(loc.homeImportGlobalProxyWarning(proxy)),
                    ),
                if (backupUserScriptCount(backup) > 0)
                  ListTile(
                    title: Text(
                      loc.homeImportUserScriptsWarning(
                        backupUserScriptCount(backup),
                      ),
                    ),
                  ),
                if (backup.globalUserScripts?.isNotEmpty == true ||
                    backup.sites.any(
                      (s) => (s['userScripts'] as List?)?.isNotEmpty == true,
                    ))
                  CheckboxListTile(
                    title: Text(loc.backupTurnOnScripts),
                    subtitle: Text(loc.homeImportHeldScriptsBody),
                    value: scripts,
                    onChanged: sites
                        ? (v) => refresh(() => scripts = v ?? false)
                        : null,
                  ),
                if (backup.webExtensions != null)
                  CheckboxListTile(
                    title: Text(loc.backupRestoreExtensions),
                    value: extensions,
                    onChanged: (v) => refresh(() => extensions = v ?? false),
                  ),
                if (backup.webExtensions case final carried?)
                  for (final extension in carried.extensions)
                    ListTile(
                      title: Text(extension.name),
                      subtitle: Text(extension.version),
                    ),
                ListTile(title: Text(loc.homeImportSettingsSessionsNote)),
              ],
            ),
            bottomNavigationBar: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    dialog,
                    BackupRestoreChoices(
                      restoreSites: sites,
                      restoreAppSettings: appSettings,
                      restoreGlobalScripts: globalScripts,
                      turnOnScripts: sites && scripts,
                      turnOnExtensions: extensions,
                    ),
                  ),
                  child: Text(loc.homeImportAction),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Future<SettingsBackup?> pick() async {
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    switch (await SettingsBackupService.pickAndImport()) {
      case Picked(:final backup):
        return backup;
      case PickCancelled():
        return null;
      case NotABackup():
        messenger.toast(loc.homeImportInvalidBackup);
        return null;
      case BackupUnreadable():
        messenger.toast(loc.backupImportUnreadable);
        return null;
    }
  }

  @override
  Future<void> save(SettingsBackup backup) async {
    final loc = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final saved = await SettingsBackupService.exportAndSave(
      backup: backup,
      dialogTitle: loc.backupSaveDialogTitle,
    );
    switch (saved) {
      case Saved():
        messenger.toast(loc.backupExported);
      case SaveCancelled():
        break;
      case SaveFailed():
        messenger.toast(loc.backupExportFailed);
    }
  }

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
    return confirm(
      context,
      title: loc.homeImportSettingsTitle,
      content: Column(
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
      confirmLabel: loc.homeImportAction,
      destructive: false,
    );
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
                script.sites.map((s) => s.getDisplayName()).join(', '),
              ),
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
                        (manifest.permissions.toList()..sort()).join(', '),
                      ),
                manifest.hosts.isEmpty
                    ? loc.extensionsReachesNothing
                    : loc.extensionsReaches(
                        (manifest.hosts.toList()..sort()).join(', '),
                      ),
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
