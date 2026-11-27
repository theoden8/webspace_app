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
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/extension_asks.dart';

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
    final selected = {for (final site in sites) site.siteId};
    final scriptSites = {for (final site in sites) site.siteId};
    final cookieSites = {for (final site in sites) site.siteId};
    final extensionSites = {for (final site in sites) site.siteId};
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
                          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
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
                        subtitle: Text(
                          loc.backupSelectionCount(
                            selected.length,
                            sites.length,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => refresh(() => section = 1),
                      ),
                      ListTile(
                        title: Text(loc.backupAppSettings),
                        subtitle: Text(
                          loc.backupSelectionCount(
                            appSettings ? appPrefKeys.length : 0,
                            AppPref.values.length,
                          ),
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
                              sites.map((s) => s.siteId),
                            );
                          }
                        }),
                      ),
                      for (final site in sites)
                        ExpansionTile(
                          leading: Checkbox(
                            value: selected.contains(site.siteId),
                            onChanged: (value) => refresh(() {
                              if (value == true) {
                                selected.add(site.siteId);
                              } else {
                                selected.remove(site.siteId);
                              }
                            }),
                          ),
                          title: Text(site.getDisplayName()),
                          children: selected.contains(site.siteId)
                              ? [
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteScripts),
                                    value: scriptSites.contains(
                                      site.siteId,
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        scriptSites.add(site.siteId);
                                      } else {
                                        scriptSites.remove(
                                          site.siteId,
                                        );
                                      }
                                    }),
                                  ),
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteCookies),
                                    value: cookieSites.contains(
                                      site.siteId,
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        cookieSites.add(site.siteId);
                                      } else {
                                        cookieSites.remove(
                                          site.siteId,
                                        );
                                      }
                                    }),
                                  ),
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteExtensions),
                                    value: extensionSites.contains(
                                      site.siteId,
                                    ),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        extensionSites.add(
                                          site.siteId,
                                        );
                                      } else {
                                        extensionSites.remove(
                                          site.siteId,
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
                        for (final group in _backupPrefGroups(
                          AppPref.values,
                          loc: loc,
                        ).entries)
                          ExpansionTile(
                            title: Text(group.key),
                            subtitle: Text(
                              loc.backupSelectionCount(
                                group.value.where((p) => appPrefKeys.contains(p.key)).length,
                                group.value.length,
                              ),
                            ),
                            children: [
                              for (final pref in group.value)
                                CheckboxListTile(
                                  title: Text(_prefTitle(pref, loc: loc)),
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
    var extensions = backup.webExtensions != null;
    final selectedSites = {
      if (backup.includesSites)
        for (var i = 0; i < backup.sites.length; i++) i,
    };
    final selectedSiteScripts = Set<int>.of(selectedSites);
    final selectedSiteCookies = Set<int>.of(selectedSites);
    final selectedSiteExtensions = Set<int>.of(selectedSites);
    final carried = _carriedPrefs(backup);
    final appPrefKeys = {for (final p in carried) p.key};
    final scriptSites = <int>{};
    final extensionSites = <int>{};
    var section = 0;
    bool hasScripts(int index) {
      if (!selectedSites.contains(index) ||
          !selectedSiteScripts.contains(index)) {
        return false;
      }
      final raw = backup.sites[index];
      final own = raw['userScripts'];
      final enabledOwn =
          own is List &&
          own.any((script) => script is Map && script['enabled'] != false);
      final optedIn = raw['enabledGlobalScriptIds'];
      return enabledOwn ||
          (globalScripts && optedIn is List && optedIn.isNotEmpty);
    }

    bool hasExtensions(int index) {
      if (!selectedSites.contains(index) ||
          !selectedSiteExtensions.contains(index) ||
          !extensions) {
        return false;
      }
      final choices = backup.sites[index]['webExtensionChoices'];
      return choices is Map && choices.values.any((on) => on == true);
    }

    final backupWebspaces = <({int sourceIndex, Webspace space})>[];
    for (var i = 0; i < backup.webspaces.length; i++) {
      final space = Webspace.fromJson(backup.webspaces[i]);
      if (!space.isAll) backupWebspaces.add((sourceIndex: i, space: space));
    }
    final selectedWebspaceIndices = {
      if (backup.includesSites)
        for (final entry in backupWebspaces) entry.sourceIndex,
    };
    bool hasSiteScope() =>
        selectedSites.isNotEmpty || selectedWebspaceIndices.isNotEmpty;
    sites = backup.includesSites && hasSiteScope();
    final siteIndexById = <String, int>{};
    for (var i = 0; i < backup.sites.length; i++) {
      final id = backup.sites[i]['siteId'];
      if (id is String) siteIndexById.putIfAbsent(id, () => i);
    }
    final webspaceSiteIndices = <List<int>>[];
    for (final entry in backupWebspaces) {
      final space = entry.space;
      final members = <int>{
        for (final index in space.siteIndices)
          if (index >= 0 && index < backup.sites.length) index,
        for (final id in space.siteIds)
          if (siteIndexById[id] case final index?) index,
      };
      webspaceSiteIndices.add(members.toList()..sort());
    }

    return showDialog<BackupRestoreChoices>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => PopScope(
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
                        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => refresh(() => section = 0),
                      ),
                title: Text(switch (section) {
                  1 => loc.backupRestoreContents,
                  2 => loc.backupChooseSiteActivation,
                  3 => loc.backupChooseImportSites,
                  4 => loc.backupChooseAppSettings,
                  _ => loc.backupRestoreTitle,
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
                      title: Text(
                        loc.homeImportExportedLabel(
                          backup.exportedAt
                              .toLocal()
                              .toString()
                              .split('.')
                              .first,
                        ),
                      ),
                    ),
                    ListTile(
                      title: Text(loc.backupRestoreContents),
                      subtitle: Text(
                        loc.webspacesListSiteCount(selectedSites.length),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => refresh(() => section = 1),
                    ),
                    if (sites && backup.sites.isNotEmpty)
                      ListTile(title: Text(loc.backupReplaceSitesNote)),
                    const Divider(),
                    ListTile(title: Text(loc.backupAfterRestore)),
                    if (List.generate(
                      backup.sites.length,
                      (i) => i,
                    ).any((i) => hasScripts(i) || hasExtensions(i)))
                      ListTile(
                        title: Text(loc.backupChooseSiteActivation),
                        subtitle: Text(
                          loc.backupSelectionCount(
                            {...scriptSites, ...extensionSites}.length,
                            backup.sites.length,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: sites,
                        onTap: () => refresh(() => section = 2),
                      ),
                    ListTile(title: Text(loc.homeImportSettingsSessionsNote)),
                    if (selectedSiteCookies
                        .intersection(selectedSites)
                        .isNotEmpty)
                      ListTile(title: Text(loc.backupCookiesSessionNote)),
                  ],
                  if (section == 1) ...[
                    ListTile(
                      title: Text(loc.backupAllSites),
                      subtitle: Text(
                        loc.backupSelectionCount(
                          selectedSites.length,
                          backup.sites.length,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: backup.includesSites,
                      onTap: () => refresh(() => section = 3),
                    ),
                    ListTile(
                      title: Text(loc.backupAppSettings),
                      subtitle: Text(
                        loc.backupSelectionCount(
                          appSettings ? appPrefKeys.length : 0,
                          backup.globalPrefs.length,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: backup.includesAppSettings,
                      onTap: () => refresh(() => section = 4),
                    ),
                    if (backup.globalUserScripts != null)
                      CheckboxListTile(
                        title: Text(loc.backupGlobalScripts),
                        value: globalScripts,
                        onChanged: (v) =>
                            refresh(() => globalScripts = v ?? false),
                      ),
                    if (backup.webExtensions != null)
                      CheckboxListTile(
                        title: Text(loc.backupRestoreExtensions),
                        value: extensions,
                        onChanged: (v) => refresh(() {
                          extensions = v ?? false;
                          if (!extensions) extensionSites.clear();
                        }),
                      ),
                    if (appSettings)
                      if (backupGlobalProxyAddress(backup) case final proxy?)
                        ListTile(
                          title: Text(loc.homeImportGlobalProxyWarning(proxy)),
                        ),
                    if (backup.webExtensions case final carried?)
                      ExpansionTile(
                        title: Text(loc.backupExtensionsTitle),
                        children: [
                          for (final extension in carried.extensions)
                            ListTile(
                              title: Text(extension.name),
                              subtitle: Text(extension.version),
                            ),
                        ],
                      ),
                  ],
                  if (section == 2) ...[
                    ListTile(title: Text(loc.backupActivationNote)),
                    for (var i = 0; i < backup.sites.length; i++)
                      if (hasScripts(i) || hasExtensions(i))
                        ExpansionTile(
                          title: Text(
                            backup.sites[i]['name'] is String
                                ? backup.sites[i]['name'] as String
                                : loc.backupUnnamedSite(i + 1),
                          ),
                          children: [
                            if (hasScripts(i))
                              CheckboxListTile(
                                title: Text(loc.backupRunSiteScripts),
                                value: scriptSites.contains(i),
                                onChanged: (v) => refresh(() {
                                  if (v == true) {
                                    scriptSites.add(i);
                                  } else {
                                    scriptSites.remove(i);
                                  }
                                }),
                              ),
                            if (hasExtensions(i) &&
                                backup.webExtensions != null)
                              CheckboxListTile(
                                title: Text(loc.backupRunSiteExtensions),
                                value: extensionSites.contains(i),
                                onChanged: extensions
                                    ? (v) => refresh(() {
                                        if (v == true) {
                                          extensionSites.add(i);
                                        } else {
                                          extensionSites.remove(i);
                                        }
                                      })
                                    : null,
                              ),
                          ],
                        ),
                  ],
                  if (section == 3) ...[
                    CheckboxListTile(
                      title: Text(loc.backupAllSites),
                      value:
                          selectedSites.length == backup.sites.length &&
                          backup.sites.isNotEmpty,
                      onChanged: (v) => refresh(() {
                        selectedSites.clear();
                        selectedWebspaceIndices.clear();
                        if (v == true) {
                          selectedSites.addAll(
                            List.generate(
                              backup.sites.length,
                              (index) => index,
                            ),
                          );
                          selectedWebspaceIndices.addAll(
                            backupWebspaces.map((entry) => entry.sourceIndex),
                          );
                        } else {
                          scriptSites.clear();
                          extensionSites.clear();
                        }
                        sites = hasSiteScope();
                      }),
                    ),
                    if (backupWebspaces.isNotEmpty) ...[
                      ListTile(title: Text(loc.backupWholeWebspaces)),
                      for (var w = 0; w < backupWebspaces.length; w++)
                        CheckboxListTile(
                          title: Text(backupWebspaces[w].space.name),
                          subtitle: Text(
                            loc.backupSelectionCount(
                              webspaceSiteIndices[w]
                                  .where(selectedSites.contains)
                                  .length,
                              webspaceSiteIndices[w].length,
                            ),
                          ),
                          value: selectedWebspaceIndices.contains(
                            backupWebspaces[w].sourceIndex,
                          ),
                          onChanged: (v) => refresh(() {
                            if (v == true) {
                              selectedWebspaceIndices.add(
                                backupWebspaces[w].sourceIndex,
                              );
                              selectedSites.addAll(webspaceSiteIndices[w]);
                            } else {
                              selectedWebspaceIndices.remove(
                                backupWebspaces[w].sourceIndex,
                              );
                              final sitesInOtherSelectedWebspaces = <int>{
                                for (
                                  var other = 0;
                                  other < backupWebspaces.length;
                                  other++
                                )
                                  if (selectedWebspaceIndices.contains(
                                    backupWebspaces[other].sourceIndex,
                                  ))
                                    ...webspaceSiteIndices[other],
                              };
                              final removedSites = webspaceSiteIndices[w]
                                  .where(
                                    (index) => !sitesInOtherSelectedWebspaces
                                        .contains(index),
                                  )
                                  .toSet();
                              selectedSites.removeAll(removedSites);
                              scriptSites.removeAll(removedSites);
                              extensionSites.removeAll(removedSites);
                            }
                            sites = hasSiteScope();
                          }),
                        ),
                      const Divider(),
                    ],
                    ListTile(title: Text(loc.backupIndividualSites)),
                    for (var i = 0; i < backup.sites.length; i++)
                      ExpansionTile(
                        leading: Checkbox(
                          value: selectedSites.contains(i),
                          onChanged: (v) => refresh(() {
                            if (v == true) {
                              selectedSites.add(i);
                            } else {
                              selectedSites.remove(i);
                              scriptSites.remove(i);
                              extensionSites.remove(i);
                            }
                            sites = hasSiteScope();
                          }),
                        ),
                        title: Text(
                          backup.sites[i]['name'] is String
                              ? backup.sites[i]['name'] as String
                              : loc.backupUnnamedSite(i + 1),
                        ),
                        children: selectedSites.contains(i)
                            ? [
                                CheckboxListTile(
                                  title: Text(loc.backupSiteScripts),
                                  value: selectedSiteScripts.contains(i),
                                  onChanged: (v) => refresh(() {
                                    if (v == true) {
                                      selectedSiteScripts.add(i);
                                    } else {
                                      selectedSiteScripts.remove(i);
                                      scriptSites.remove(i);
                                    }
                                  }),
                                ),
                                CheckboxListTile(
                                  title: Text(loc.backupSiteCookies),
                                  value: selectedSiteCookies.contains(i),
                                  onChanged: (v) => refresh(() {
                                    if (v == true) {
                                      selectedSiteCookies.add(i);
                                    } else {
                                      selectedSiteCookies.remove(i);
                                    }
                                  }),
                                ),
                                if (backup.webExtensions != null)
                                  CheckboxListTile(
                                    title: Text(loc.backupSiteExtensions),
                                    value: selectedSiteExtensions.contains(i),
                                    onChanged: (v) => refresh(() {
                                      if (v == true) {
                                        selectedSiteExtensions.add(i);
                                      } else {
                                        selectedSiteExtensions.remove(i);
                                        extensionSites.remove(i);
                                      }
                                    }),
                                  ),
                              ]
                            : const [],
                      ),
                  ],
                  if (section == 4) ...[
                    CheckboxListTile(
                      title: Text(loc.backupAppSettings),
                      value: appSettings,
                      onChanged: (v) => refresh(() => appSettings = v ?? false),
                    ),
                    if (appSettings)
                      for (final group in _backupPrefGroups(
                        carried,
                        loc: loc,
                      ).entries)
                        ExpansionTile(
                          title: Text(group.key),
                          subtitle: Text(
                            loc.backupSelectionCount(
                              group.value.where((p) => appPrefKeys.contains(p.key)).length,
                              group.value.length,
                            ),
                          ),
                          children: [
                            for (final pref in group.value)
                              CheckboxListTile(
                                title: Text(_prefTitle(pref, loc: loc)),
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
                            BackupRestoreChoices(
                              restoreSites: sites,
                              restoreAppSettings: appSettings,
                              restoreGlobalScripts: globalScripts,
                              restoreExtensions: extensions,
                              siteIndices: selectedSites,
                              webspaceIndices: sites
                                  ? selectedWebspaceIndices
                                  : const {},
                              siteScriptIndices: selectedSiteScripts
                                  .intersection(selectedSites),
                              siteCookieIndices: selectedSiteCookies
                                  .intersection(selectedSites),
                              siteExtensionIndices: selectedSiteExtensions
                                  .intersection(selectedSites),
                              appPrefKeys: appPrefKeys,
                              scriptSiteIndices: sites ? scriptSites : const {},
                              extensionSiteIndices: sites && extensions
                                  ? extensionSites
                                  : const {},
                            ),
                          ),
                    child: Text(
                      section == 0 ? loc.homeImportAction : loc.commonDone,
                    ),
                  ),
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
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                ...extensionAsks(
                  permissions: manifest.permissions,
                  hosts: manifest.hosts,
                  loc: loc,
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

/// [pref]'s title as its settings row shows it, or as the backup review
/// names a pref no row sets.
String _prefTitle(AppPref pref, {required AppLocalizations loc}) =>
    switch (pref) {
      AppPref.showUrlBar => loc.homeShowUrlBarMenu,
      AppPref.tabsEnabled => loc.siteSettingsTabs,
      AppPref.externalLinkMode => loc.siteSettingsExternalLinks,
      AppPref.routeOutboundLinks => loc.siteSettingsRouteOutboundLinks,
      AppPref.signInPopups => loc.siteSettingsSignInPopups,
      AppPref.siteNavigation => loc.appSettingsSiteNavigation,
      AppPref.fullscreenNavigation => loc.appSettingsFullscreenButton,
      AppPref.sidebarState => loc.backupPrefSidebarState,
      AppPref.sidebarStyle => loc.appSettingsSidebarStyle,
      AppPref.sidebarWidth => loc.backupPrefSidebarWidth,
      AppPref.sidebarExpandOnHover => loc.appSettingsSidebarExpandOnHover,
      AppPref.sidebarHandleY => loc.backupPrefSidebarHandle,
      AppPref.siteStripHidden => loc.backupPrefSiteStripHidden,
      AppPref.tabStripEdge => loc.appSettingsSiteStripPosition,
      AppPref.tabBarButtonOnRight => loc.backupPrefTabButtonCorner,
      AppPref.fullscreenOnShortcut => loc.appSettingsFullscreenOnShortcut,
      AppPref.tabMaxWidth => loc.appSettingsTabMaxWidth,
      AppPref.showStatsBanner => loc.appSettingsStatsBar,
      AppPref.osmTileUrl => loc.appSettingsTileUrl,
      AppPref.globalOutboundProxy => loc.appSettingsOutboundProxy,
      AppPref.proxyLibrary => loc.savedProxiesTitle,
      AppPref.developerMode => loc.appSettingsDeveloperMode,
      AppPref.experimentalTextureRendering =>
        loc.appSettingsExperimentalTextureRendering,
      AppPref.webExtensionsCheckUpdates => loc.extensionsCheckDaily,
      AppPref.webExtensionsAutoUpdate => loc.extensionsAutoUpdate,
      AppPref.experimentalNetworkInterface =>
        loc.appSettingsExperimentalNetworkInterface,
      AppPref.experimentalWebKitBlockReports =>
        loc.appSettingsExperimentalWebKitBlockReports,
      AppPref.externalTor => loc.externalTor,
      AppPref.externalTorAddress => loc.externalTorAddress,
      AppPref.externalTorControl => loc.externalTorControl,
      AppPref.linkHandlingEnabled => loc.appSettingsLinkHandling,
      AppPref.linkHandlingClaimDomains =>
        loc.linkHandlingClaimDomainsToggleTitle,
      AppPref.webSearchDefaultSite => loc.webSearchDefaultTitle,
      AppPref.useUboResources => loc.appSettingsUboRedirectStubs,
      AppPref.appLocaleOverride => loc.appSettingsLanguageTitle,
      AppPref.firefoxUaAutoRefresh => loc.appSettingsFirefoxAutoUpdate,
      AppPref.backForwardCacheEnabled => loc.backupPrefBackForwardCache,
      AppPref.backOpensMenu => loc.appSettingsBackOpensMenu,
      AppPref.httpsUpgradeEnabled => loc.siteSettingsHttpsUpgrade,
      AppPref.blockScreenshots => loc.siteSettingsBlockScreenshots,
      AppPref.legacyDesign => loc.appSettingsLegacyDesign,
      AppPref.libraryLayout => loc.backupPrefFolderLayout,
      AppPref.libraryWebspaceLayout => loc.backupPrefWebspacesLayout,
      AppPref.libraryIconSize => loc.appSettingsLibraryIconSize,
      AppPref.keepRunningWhenClosed => loc.appSettingsKeepRunningWhenClosed,
      AppPref.topSitesKeepFilters => loc.topSitesKeepFilters,
      AppPref.topSitesOffer => loc.topSitesOffer,
    };

/// The prefs [backup] names, under their key or the one an older build
/// wrote them under.
List<AppPref> _carriedPrefs(SettingsBackup backup) => [
  for (final p in AppPref.values)
    if (backup.globalPrefs.containsKey(p.key) ||
        backup.globalPrefs.containsKey(p.legacyKey))
      p,
];

/// [prefs] under the title of the App Settings screen each belongs
/// to ([AppPref.section]), in the screens' order.
Map<String, List<AppPref>> _backupPrefGroups(
  Iterable<AppPref> prefs, {
  required AppLocalizations loc,
}) {
  String title(PrefSection section) => switch (section) {
    PrefSection.appearance => loc.appSettingsAppearance,
    PrefSection.behaviour => loc.appSettingsBehaviour,
    PrefSection.privacy => loc.appSettingsPrivacy,
    PrefSection.network => loc.appSettingsNetwork,
    PrefSection.extensions => loc.appSettingsExtensions,
    PrefSection.experimental => loc.appSettingsExperimental,
  };
  return {
    for (final section in PrefSection.values)
      if (prefs.any((p) => p.section == section))
        title(section): [
          for (final p in prefs)
            if (p.section == section) p,
        ],
  };
}
