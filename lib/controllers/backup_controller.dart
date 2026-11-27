import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/runtime/arb_messages.dart';
import 'package:webspace/controllers/let_go_table.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_import.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/egress_relay.dart';
import 'package:webspace/services/egress_route_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/services/suggested_sites_service.dart'
    as suggested_sites;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/ubo_backup_import.dart'
    show UboTrustedSite, hostTrustedBy;
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/site_suggestion.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';

class BackupExportChoices {
  const BackupExportChoices({
    required this.siteIds,
    required this.siteScriptIds,
    required this.siteCookieIds,
    required this.siteExtensionIds,
    required this.appSettings,
    required this.appPrefKeys,
    required this.siteScripts,
    required this.globalScripts,
    required this.extensionCarry,
  });
  final Set<SiteId> siteIds;
  final Set<SiteId> siteScriptIds;
  final Set<SiteId> siteCookieIds;
  final Set<SiteId> siteExtensionIds;
  final bool appSettings;
  final Set<String> appPrefKeys;
  final bool siteScripts;
  final bool globalScripts;
  final ExtensionCarry extensionCarry;
}

class BackupRestoreChoices {
  const BackupRestoreChoices({
    required this.restoreSites,
    required this.restoreAppSettings,
    required this.restoreGlobalScripts,
    required this.restoreExtensions,
    required this.siteIndices,
    required this.webspaceIndices,
    required this.siteScriptIndices,
    required this.siteCookieIndices,
    required this.siteExtensionIndices,
    required this.appPrefKeys,
    required this.scriptSiteIndices,
    required this.extensionSiteIndices,
  });
  final bool restoreSites;
  final bool restoreAppSettings;
  final bool restoreGlobalScripts;
  final bool restoreExtensions;
  final Set<int> siteIndices;
  final Set<int> webspaceIndices;
  final Set<int> siteScriptIndices;
  final Set<int> siteCookieIndices;
  final Set<int> siteExtensionIndices;
  final Set<String> appPrefKeys;
  final Set<int> scriptSiteIndices;
  final Set<int> extensionSiteIndices;
}

/// What a settings backup asks the user.
abstract interface class BackupPrompts {
  Future<BackupExportChoices?> configureExport(
    List<WebViewModel> sites, {
    required ExtensionCarryOffer? extensions,
    bool siteOnly = false,
  });
  Future<BackupRestoreChoices?> reviewImport(SettingsBackup backup);

  /// The backup file the user picks, or null.
  Future<SettingsBackup?> pick();

  /// Whether to replace the app's sites and settings with [backup]'s.
  Future<bool> confirmImport(SettingsBackup backup);

  /// Writes [backup] where the user chooses.
  Future<void> save(SettingsBackup backup);

  /// Whether to run [held], the scripts the backup ran, again where it ran
  /// them.
  Future<bool> confirmRestoreScripts(List<HeldScript> held);

  /// How the backup carries the extension library, each choice with its
  /// size; null cancels the export (WEBEXT-011).
  Future<ExtensionCarry?> chooseExtensionCarry(ExtensionCarryOffer offer);

  /// Whether to add [packages], the extensions the backup carries files of
  /// that this device lacks (WEBEXT-011).
  Future<bool> confirmAddExtensions(List<ExtensionPackage> packages);
}

/// What a backup asks of the page.
abstract interface class BackupHost implements PageHost {
  Future<void> activate(WebViewModel? site);

  /// The app's theme follows [ShellStore.theme].
  void themeChanged();
}

/// Settings export and import (BACKUP-*), and the uBO trust list a backup of
/// uBlock Origin's carries.
class BackupController {
  BackupController(
    this._sites, {
    required BackupHost host,
    required BackupPrompts prompts,
    required ShellStore shell,
    required ArchiveController archives,
    required BackgroundSitesController background,
    required SiteImport imports,
  }) : _host = host,
       _prompts = prompts,
       _shell = shell,
       _archives = archives,
       _background = background,
       _imports = imports;

  final SiteRuntime _sites;
  final BackupHost _host;
  final BackupPrompts _prompts;
  final ShellStore _shell;
  final ArchiveController _archives;
  final BackgroundSitesController _background;
  final SiteImport _imports;

  Future<void> export({SiteId? onlySite}) async {
    final prefs = await SharedPreferences.getInstance();
    // The global proxy password is in secure storage, not in the prefs
    // value `readExportedAppPrefs` reads — and per PWD-005 we do NOT
    // re-inject it for export (same as secure cookies).
    // ARCH-010: exports never include archive-tier state, even when an
    // archive is open. Filter on `isArchiveTier` so the export bytes
    // match what a user with zero archives would produce.
    final appTierModels = _sites.models
        .where(
          (m) => !m.isArchiveTier && (onlySite == null || m.siteId == onlySite),
        )
        .toList();

    // A backup of one site carries nothing of the others: no open
    // archive, and only the extensions the site has choices for.
    final extraSections = onlySite == null
        ? await _archives.sectionsForExport()
        : null;
    if (!_host.mounted) return;

    final ExtensionCarryOffer? offer;
    final library = WebExtensionLibrary.instance;
    final only = onlySite == null
        ? null
        : {for (final m in appTierModels) ...m.webExtensionChoices.keys};
    if (library.installed.value.isEmpty || (only != null && only.isEmpty)) {
      offer = null;
    } else {
      try {
        offer = await library.carryOffer(only: only);
      } on IOException catch (e) {
        LogTag.webExtension.info('export left extensions out: $e');
        _host.toast((loc) => loc.backupExtensionsUnreadable);
        return;
      }
    }

    if (!_host.mounted) return;
    final choices = await _prompts.configureExport(
      appTierModels,
      extensions: offer,
      siteOnly: onlySite != null,
    );
    if (choices == null || !_host.mounted) return;
    final selected = appTierModels
        .where((site) => choices.siteIds.contains(site.siteId))
        .toList();
    final everySite =
        onlySite == null && selected.length == appTierModels.length;
    final webspaces = webspacesForExport(
      ArchiveMembershipEngine.persistable(
        _sites.webspaces,
        archivedSiteIds: _shell.archivedSiteIds,
      ),
      sites: {for (final m in selected) m.siteId},
      everySite: everySite,
    );
    final webExtensions = offer == null
        ? null
        : extensionSectionFor(choices.extensionCarry, offer: offer);

    await _prompts.save(
      SettingsBackupService.createBackup(
        includesSites: selected.isNotEmpty,
        includesAppSettings: choices.appSettings,
        includeSiteScripts: choices.siteScripts,
        siteScriptIds: choices.siteScriptIds,
        siteCookieIds: choices.siteCookieIds,
        siteExtensionIds: choices.siteExtensionIds,
        includeGlobalScriptChoices: choices.globalScripts,
        webViewModels: selected,
        webspaces: webspaces,
        themeMode: _shell.theme.toStorageIndex(),
        globalPrefs: choices.appSettings
            ? (readExportedAppPrefs(prefs)
                ..removeWhere((key, _) => !choices.appPrefKeys.contains(key)))
            : null,
        selectedWebspaceId:
            webspaces.any((w) => w.id == _sites.selectedWebspaceId)
            ? _sites.selectedWebspaceId
            : null,
        // A row among the exported sites, which an archive-tier row before
        // the shown site would shift.
        currentIndex: switch (_sites.shown) {
          final shown? when selected.holdsObject(shown) =>
            selected.indexOfObject(shown),
          _ => null,
        },
        suggestedSites: choices.appSettings
            ? _shell.suggestedSites
                  .map(
                    (s) => {'name': s.name, 'url': s.url, 'domain': s.domain},
                  )
                  .toList()
            : null,
        globalUserScripts: choices.globalScripts
            ? _shell.globalUserScripts.map((s) => s.toJson()).toList()
            : null,
        // User intent for the downloaded-data blockers: the chosen DNS
        // severity level and the content-blocker list selection. The blobs
        // themselves stay machine state; the user re-downloads after import.
        dnsBlockLevel: choices.appSettings
            ? DnsBlockService.instance.level
            : null,
        contentBlockerLists: choices.appSettings
            ? ContentBlockerService.instance.exportListSelection()
            : null,
        extraSections: extraSections,
        webExtensions: webExtensions,
      ),
    );
  }

  /// Gives each restored site back its choices for the backup's extensions
  /// this device has, or adds once the user accepts (WEBEXT-011). Returns
  /// how many it could neither link nor add.
  Future<int> _restoreExtensions(
    SettingsImportPlan plan, {
    required Set<SiteId> enableSiteIds,
  }) async {
    final incoming = plan.webExtensions;
    if (incoming == null) return 0;
    final restored = await WebExtensionLibrary.instance.restoreFromBackup(
      incoming,
      confirmAdd: (packages) async =>
          _host.mounted && await _prompts.confirmAddExtensions(packages),
    );
    for (final (:site, :choices) in plan.heldExtensionChoices) {
      final linked = relinkChoices(choices, links: restored.links);
      site.webExtensionChoices = {
        for (final MapEntry(key: id, value: wasOn) in linked.entries)
          id: enableSiteIds.contains(site.siteId) && wasOn,
      };
    }
    return restored.missing;
  }

  /// uBO trusts a site by switching all filtering off on it; the per-site
  /// content-blocker toggle is the equivalent here. Archive-tier sites are
  /// left alone (ARCH-006), and so are sites whose Tracking Protection
  /// would hold the blocker on regardless.
  Future<List<UboTrustedSite>> trustUboHosts(
    Set<String> hosts, {
    required bool apply,
  }) async {
    final matched = <WebViewModel>[];
    for (final m in _sites.models) {
      if (m.isArchiveTier || !m.contentBlockEnabled) continue;
      if (m.trackingProtectionEnabled) continue;
      final host = Uri.tryParse(m.initUrl)?.host ?? '';
      if (host.isNotEmpty && hostTrustedBy(host, trustedHosts: hosts)) {
        matched.add(m);
      }
    }
    final result = [
      for (final m in matched)
        UboTrustedSite(m.getDisplayName(), host: Uri.parse(m.initUrl).host),
    ];
    if (apply && matched.isNotEmpty) {
      for (final m in matched) {
        m.contentBlockEnabled = false;
        LetGoTable.letGo(_sites, site: m);
      }
      _host.rebuild();
      await _host.commitSites(const SitesEdited());
    }
    return result;
  }

  Future<void> import() async {
    final backup = await _prompts.pick();
    if (backup == null) {
      return;
    }

    final restoreChoices = await _prompts.reviewImport(backup);
    if (restoreChoices == null) {
      return;
    }

    // Decide the whole import BEFORE touching live state: a site entry that
    // does not parse throws here, and a malformed/hostile backup would
    // otherwise leave the user with their sites already cleared and the
    // restore half-done.
    final partialSiteImport =
        restoreChoices.restoreSites &&
        (restoreChoices.siteIndices.length < backup.sites.length ||
            (backup.sites.isEmpty &&
                restoreChoices.webspaceIndices.isNotEmpty));
    final SettingsImportPlan plan;
    try {
      plan = planSettingsImport(
        backup,
        stateSetterF: _host.rebuild,
        selectedSiteIndices: restoreChoices.siteIndices,
        selectedWebspaceIndices: restoreChoices.webspaceIndices,
        siteScriptIndices: restoreChoices.siteScriptIndices,
        siteCookieIndices: restoreChoices.siteCookieIndices,
        siteExtensionIndices: restoreChoices.siteExtensionIndices,
        keeping: partialSiteImport
            ? {
                for (final m in _sites.models)
                  if (!m.isArchiveTier) m.siteId,
              }
            : const {},
      );
    } on FormatException catch (e) {
      LogTag.import.error('Aborted import; live state left intact: $e');
      _host.toast((loc) => loc.homeImportInvalidBackup);
      return;
    }
    final remintedGlobals =
        restoreChoices.restoreGlobalScripts && plan.globalUserScripts != null
        ? remintImportedGlobalScripts(
            plan.globalUserScripts!,
            held: plan.heldScripts,
          )
        : null;

    final selectedSourceIndices =
        restoreChoices.siteIndices
            .where((index) => index >= 0 && index < backup.sites.length)
            .toList()
          ..sort();
    final importedBySource = <int, WebViewModel>{
      for (
        var row = 0;
        row < selectedSourceIndices.length && row < plan.sites.length;
        row++
      )
        selectedSourceIndices[row]: plan.sites[row],
    };
    final enableScriptSiteIds = {
      for (final index in restoreChoices.scriptSiteIndices)
        if (importedBySource[index] case final site?) site.siteId,
    };
    final enableExtensionSiteIds = {
      for (final index in restoreChoices.extensionSiteIndices)
        if (importedBySource[index] case final site?) site.siteId,
    };

    // Seal archives and apply the import in the same turn, so none opens
    // against the site rows this import is replacing (SEC-044).
    var replaced = false;
    var extensionsMissing = 0;
    final sealed = await _archives.closeAllThen((closed) async {
      if (!_host.mounted) return;
      final currentById = {
        for (final site in _sites.models)
          if (!site.isArchiveTier) site.siteId: site,
      };
      for (final MapEntry(key: index, value: site)
          in importedBySource.entries) {
        final current = currentById[site.siteId];
        if (current == null) continue;
        if (!restoreChoices.siteScriptIndices.contains(index)) {
          site.userScripts = List.of(current.userScripts);
        }
        if (!restoreChoices.restoreGlobalScripts) {
          site.enabledGlobalScriptIds = Set.of(current.enabledGlobalScriptIds);
        }
        if (!restoreChoices.siteCookieIndices.contains(index)) {
          site.cookies = List.of(current.cookies);
        }
        if (!restoreChoices.restoreExtensions ||
            !restoreChoices.siteExtensionIndices.contains(index)) {
          site.webExtensionChoices = Map.of(current.webExtensionChoices);
        }
      }

      // Applied and persisted in one step, before any site activates, so a pref
      // the backup does not name reads the same before and after a restart.
      // Per PWD-005 the backup carries no proxy password: the user re-enters
      // it on the proxy settings screen, as they re-log into sites whose secure
      // cookies were stripped.
      if (restoreChoices.restoreAppSettings) {
        final currentPrefs = readExportedAppPrefs(
          await SharedPreferences.getInstance(),
        );
        // The plan holds each pref under its key, one an older build wrote
        // under another already read across.
        for (final MapEntry(:key, :value) in plan.appPrefs.entries) {
          if (!restoreChoices.restoreSites &&
              key == AppPref.webSearchDefaultSite.key) {
            continue;
          }
          if (restoreChoices.appPrefKeys.contains(key))
            currentPrefs[key] = value;
        }
        await writeExportedAppPrefs(
          await SharedPreferences.getInstance(),
          values: resolveExportedAppPrefs(currentPrefs),
        );
      }
      if (!_host.mounted) return;
      // Every service that reads those prefs reloads before the sites commit,
      // so the Tor refcount and a DEFAULT site's first load see the imported
      // app-wide proxy, not the one it replaces.
      await DeveloperModeService.instance.reload();
      await TorService.instance.externalAddressChanged();
      await TorService.instance.runtimeChoiceChanged();
      // The imported value is password-less; the in-memory proxy follows it
      // without an app restart.
      final reloadedPrefs = await SharedPreferences.getInstance();
      await GlobalOutboundProxy.update(readGlobalOutboundProxy(reloadedPrefs));
      await ProxyLibrary.reloadAfterImport();
      // The downloaded-data blockers' user intent: the selection only, never
      // the blob, which the user re-downloads from App Settings.
      if (restoreChoices.restoreAppSettings && plan.dnsBlockLevel != null) {
        await DnsBlockService.instance.applyImportedLevel(plan.dnsBlockLevel!);
      }
      if (restoreChoices.restoreAppSettings &&
          plan.contentBlockerLists != null) {
        await ContentBlockerService.instance.importListSelection(
          plan.contentBlockerLists!,
        );
      }
      if (!_host.mounted) return;
      extensionsMissing = restoreChoices.restoreExtensions
          ? await _restoreExtensions(
              plan,
              enableSiteIds: enableExtensionSiteIds,
            )
          : 0;
      if (!_host.mounted) return;
      if (restoreChoices.restoreAppSettings) {
        _shell.theme = AppThemeSettings.fromStorageIndex(
          plan.themeStorageIndex,
        );
      }
      // On the shared jar the import empties the jar in its own turn, after
      // saving the share of each loaded site it carries again (ISO-015).
      replaced =
          !restoreChoices.restoreSites ||
          await _imports.replace(
            SitesReplaced(
              sites: plan.sites,
              webspaces: plan.webspaces,
              selectedWebspaceId: plan.selectedWebspaceId,
              closed: closed,
              // The listed sites a partial restore keeps are read as it
              // lands, not here: the awaits above let the list change.
              scope: partialSiteImport
                  ? ImportScope.merge
                  : ImportScope.replace,
              restoreCookiesForSiteIds: {
                for (final index in restoreChoices.siteCookieIndices)
                  if (importedBySource[index] case final site?) site.siteId,
              },
            ),
          );
    });
    if (!sealed) {
      _host.toast((loc) => loc.homeArchiveFull);
      return;
    }
    if (!replaced || !_host.mounted) return;

    WebViewModel? restore = switch (plan.currentIndex) {
      final i? when i >= 0 && i < _sites.models.length => _sites.models[i],
      _ => null,
    };
    if (partialSiteImport) restore = null;
    if (restoreChoices.restoreSites) await _host.activate(restore);
    if (!_host.mounted) return;
    _host.rebuild();
    _host.themeChanged();

    final importedCounts = _background.counts();
    if (importedCounts.enabled > 0) {
      BackgroundLog.instance.record(
        LogTag.siteUnload,
        message:
            'settings import: ${importedCounts.enabled} notification sites, '
            '${importedCounts.loaded} loaded until opened or the next launch',
        level: LogLevel.warning,
      );
    }
    await _shell.saveTheme();
    await _shell.saveSelectedWebspaceId();
    await _shell.saveCurrentIndex();

    if (remintedGlobals != null) {
      final cleared = clearRetainedGlobalScriptOptIns(
        _sites.models.where(
          (site) =>
              !site.isArchiveTier &&
              !plan.sites.any((imported) => identical(imported, site)),
        ),
      );
      if (cleared.isNotEmpty) {
        await _host.commitSites(const SitesEdited());
      }
      _shell.globalUserScripts = remintedGlobals.scripts;
    }
    await _shell.saveGlobalUserScripts();

    if (restoreChoices.restoreAppSettings && plan.suggestedSites != null) {
      _shell.suggestedSites = [
        for (final s in plan.suggestedSites!)
          SiteSuggestion(name: s.name, url: s.url, domain: s.domain),
      ];
      await suggested_sites.saveSuggestedSites(_shell.suggestedSites);
    }

    for (final webViewModel in _sites.models) {
      await webViewModel.reapplyTheme();
    }

    final links = [
      for (final link in await EgressRelay.instance.links()) link.name,
    ];
    final lacking = [
      for (final site in importedBySource.values)
        if (lackedInterface(
              site.proxySettings.leavesBy,
              relay: EgressRelay.instance.state,
              present: links,
            ) !=
            null)
          Localized.verbatim(site.name),
    ];
    final hinted =
        (restoreChoices.restoreAppSettings && plan.proxyPasswordsNeeded) ||
        (restoreChoices.restoreAppSettings && plan.blocklistsNeedDownload) ||
        extensionsMissing > 0 ||
        lacking.isNotEmpty;
    _host.toast((loc) {
      final hints = <String>[
        if (restoreChoices.restoreAppSettings && plan.proxyPasswordsNeeded)
          loc.homeImportProxyPasswordsHint,
        if (restoreChoices.restoreAppSettings && plan.blocklistsNeedDownload)
          loc.homeImportBlocklistRedownloadHint,
        if (extensionsMissing > 0)
          loc.homeImportExtensionsMissingHint(extensionsMissing),
        if (lacking.isNotEmpty)
          loc.homeImportInterfacesMissingHint(
            Localized.joined(lacking, by: Joined.list),
          ),
      ];
      return hints.isEmpty
          ? loc.homeSettingsImportedSuccess
          : loc.homeSettingsImportedWithHints(hints.join(' '));
    }, duration: Duration(seconds: hinted ? 6 : 4));

    // BACKUP-015: the scripts the backup ran come back as they were, but
    // only once the user has seen them named and said yes.
    final heldScripts = heldScriptsForSites(
      remintedGlobals?.held ?? plan.heldScripts,
      siteIds: enableScriptSiteIds,
      includeGlobalScripts: restoreChoices.restoreGlobalScripts,
    );
    if (heldScripts.isNotEmpty &&
        _host.mounted &&
        await _prompts.confirmRestoreScripts(heldScripts) &&
        _host.mounted) {
      for (final script in heldScripts) {
        script.release();
        for (final site in script.sites) {
          LetGoTable.letGo(_sites, site: site);
        }
      }
      _host.rebuild();
      await _host.commitSites(const SitesEdited());
    }

    // If the backup carries encrypted sections, offer to restore them
    // by passphrase. Each prompt restores the section(s) matching the
    // entered passphrase; remaining ones can be restored by entering
    // another passphrase, or skipped by cancelling.
    if (plan.extraSections.isNotEmpty && _host.mounted) {
      await _archives.restoreSections(plan.extraSections);
    }
  }
}
