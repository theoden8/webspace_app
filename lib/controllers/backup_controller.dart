import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/ubo_backup_import.dart' show UboTrustedSite, hostTrustedBy;
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/web_extension_backup_engine.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_suggestion.dart';
import 'package:webspace/settings/web_extension_backup.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';

/// What a settings backup asks the user.
abstract interface class BackupPrompts {
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
  })  : _host = host,
        _prompts = prompts,
        _shell = shell,
        _archives = archives,
        _background = background;

  final SiteRuntime _sites;
  final BackupHost _host;
  final BackupPrompts _prompts;
  final ShellStore _shell;
  final ArchiveController _archives;
  final BackgroundSitesController _background;

  Future<void> export() async {
    final prefs = await SharedPreferences.getInstance();
    // The global proxy password is in secure storage, not in the prefs
    // value `readExportedAppPrefs` reads — and per PWD-005 we do NOT
    // re-inject it for export (same as secure cookies).
    // ARCH-010: exports never include archive-tier state, even when an
    // archive is open. Filter on `isArchiveTier` so the export bytes
    // match what a user with zero archives would produce.
    final appTierModels =
        _sites.models.where((m) => !m.isArchiveTier).toList();

    final extraSections = await _archives.sectionsForExport();
    if (!_host.mounted) return;

    final BackupExtensions? webExtensions;
    final library = WebExtensionLibrary.instance;
    if (library.installed.value.isEmpty) {
      webExtensions = null;
    } else {
      final ExtensionCarryOffer offer;
      try {
        offer = await library.carryOffer();
      } on IOException catch (e) {
        LogTag.webExtension.info('export left extensions out: $e');
        _host.toast((loc) => loc.backupExtensionsUnreadable);
        return;
      }
      if (!_host.mounted) return;
      final carry = await _prompts.chooseExtensionCarry(offer);
      if (carry == null || !_host.mounted) return;
      webExtensions = extensionSectionFor(carry, offer: offer);
    }

    await _prompts.save(SettingsBackupService.createBackup(
      webViewModels: appTierModels,
      webspaces: ArchiveMembershipEngine.persistable(
        _sites.webspaces,
        archivedSiteIds: _shell.archivedSiteIds,
      ),
      themeMode: _shell.theme.toStorageIndex(),
      globalPrefs: readExportedAppPrefs(prefs),
      selectedWebspaceId: _sites.selectedWebspaceId,
      // A row among the exported sites, which an archive-tier row before
      // the shown site would shift.
      currentIndex: switch (_sites.shown) {
        final shown? when appTierModels.contains(shown) =>
          appTierModels.indexOf(shown),
        _ => null,
      },
      suggestedSites: _shell.suggestedSites
          .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
          .toList(),
      globalUserScripts: _shell.globalUserScripts.map((s) => s.toJson()).toList(),
      // User intent for the downloaded-data blockers: the chosen DNS
      // severity level and the content-blocker list selection. The blobs
      // themselves stay machine state; the user re-downloads after import.
      dnsBlockLevel: DnsBlockService.instance.level,
      contentBlockerLists: ContentBlockerService.instance.exportListSelection(),
      extraSections: extraSections,
      webExtensions: webExtensions,
    ));
  }

  /// Gives each restored site back its choices for the backup's extensions
  /// this device has, or adds once the user accepts (WEBEXT-011). Returns
  /// how many it could neither link nor add.
  Future<int> _restoreExtensions(SettingsImportPlan plan) async {
    final incoming = plan.webExtensions;
    if (incoming == null) return 0;
    final restored = await WebExtensionLibrary.instance.restoreFromBackup(
      incoming,
      confirmAdd: (packages) async =>
          _host.mounted && await _prompts.confirmAddExtensions(packages),
    );
    for (final (:site, :choices) in plan.heldExtensionChoices) {
      site.webExtensionChoices = relinkChoices(choices, links: restored.links);
    }
    return restored.missing;
  }

  /// uBO trusts a site by switching all filtering off on it; the per-site
  /// content-blocker toggle is the equivalent here. Archive-tier sites are
  /// left alone (ARCH-006), and so are sites whose Tracking Protection
  /// would hold the blocker on regardless.
  Future<List<UboTrustedSite>> trustUboHosts(Set<String> hosts,
      {required bool apply}) async {
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
        UboTrustedSite(m.getDisplayName(), host: Uri.parse(m.initUrl).host)
    ];
    if (apply && matched.isNotEmpty) {
      for (final m in matched) {
        m.contentBlockEnabled = false;
        m.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
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

    final confirmed = await _prompts.confirmImport(backup);
    if (confirmed != true) {
      return;
    }

    // Decide the whole import BEFORE touching live state: a site entry that
    // does not parse throws here, and a malformed/hostile backup would
    // otherwise leave the user with their sites already cleared and the
    // restore half-done.
    final SettingsImportPlan plan;
    try {
      plan = planSettingsImport(backup, stateSetterF: _host.rebuild);
    } on FormatException catch (e) {
      LogTag.import.error('Aborted import; live state left intact: $e');
      _host.toast((loc) => loc.homeImportInvalidBackup);
      return;
    }

    // ARCH-010 seals open archives before the rows they were materialised
    // into are replaced; one that does not fit its slot stays open, and the
    // import waits for it rather than replacing its rows (ARCH-011).
    if (!await _archives.closeAll()) {
      _host.toast((loc) => loc.homeArchiveFull);
      return;
    }
    if (!_host.mounted) return;

    // Applied and persisted in one step, before any site activates, so a pref
    // the backup does not name reads the same before and after a restart.
    // Per PWD-005 the backup carries no proxy password: the user re-enters
    // it on the proxy settings screen, as they re-log into sites whose secure
    // cookies were stripped.
    await writeExportedAppPrefs(
        await SharedPreferences.getInstance(), values: plan.appPrefs);
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
    if (plan.dnsBlockLevel != null) {
      await DnsBlockService.instance.applyImportedLevel(plan.dnsBlockLevel!);
    }
    if (plan.contentBlockerLists != null) {
      await ContentBlockerService.instance
          .importListSelection(plan.contentBlockerLists!);
    }
    if (!_host.mounted) return;
    final extensionsMissing = await _restoreExtensions(plan);
    if (!_host.mounted) return;
    _shell.theme = AppThemeSettings.fromStorageIndex(plan.themeStorageIndex);
    await _host.commitSites(SitesReplaced(
      sites: plan.sites,
      webspaces: plan.webspaces,
      selectedWebspaceId: plan.selectedWebspaceId,
    ));
    if (!_host.mounted) return;

    // The site, read before the jar clear's await can move the rows.
    final restore = switch (plan.currentIndex) {
      final i? when i >= 0 && i < _sites.models.length => _sites.models[i],
      _ => null,
    };
    // With no site activated no restore empties the shared jar, so what
    // the replaced sites left there would stay. Under containers there is no
    // shared jar, and no clear is issued without a site in hand (BUG-007).
    if ((restore, _sites.isolation) case (null, SharedJar(:final jar))) {
      try {
        await jar.clearUnloaded(loaded: _sites.loaded);
      } on CookieJarFailure catch (e) {
        // No site is shown, and the next activation empties the jar before
        // one is (ISO-012), so the import goes on.
        LogTag.import.warning('Jar clear after import failed: $e');
      }
    }
    await _host.activate(restore);
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

    if (plan.globalUserScripts != null) {
      _shell.globalUserScripts = plan.globalUserScripts!;
    }
    await _shell.saveGlobalUserScripts();

    if (plan.suggestedSites != null) {
      _shell.suggestedSites = [
        for (final s in plan.suggestedSites!)
          SiteSuggestion(name: s.name, url: s.url, domain: s.domain),
      ];
      await suggested_sites.saveSuggestedSites(_shell.suggestedSites);
    }

    final webViewTheme = _shell.theme.themeMode.webViewTheme;
    for (var webViewModel in _sites.models) {
      await webViewModel.setAppTheme(webViewTheme);
    }

    final hinted = plan.proxyPasswordsNeeded ||
        plan.blocklistsNeedDownload ||
        extensionsMissing > 0;
    _host.toast(
      (loc) {
        final hints = <String>[
          if (plan.proxyPasswordsNeeded) loc.homeImportProxyPasswordsHint,
          if (plan.blocklistsNeedDownload) loc.homeImportBlocklistRedownloadHint,
          if (extensionsMissing > 0)
            loc.homeImportExtensionsMissingHint(extensionsMissing),
        ];
        return hints.isEmpty
            ? loc.homeSettingsImportedSuccess
            : loc.homeSettingsImportedWithHints(hints.join(' '));
      },
      duration: Duration(seconds: hinted ? 6 : 4),
    );

    // BACKUP-015: the scripts the backup ran come back as they were, but
    // only once the user has seen them named and said yes.
    if (plan.heldScripts.isNotEmpty &&
        _host.mounted &&
        await _prompts.confirmRestoreScripts(plan.heldScripts) &&
        _host.mounted) {
      for (final script in plan.heldScripts) {
        script.release();
        for (final site in script.sites) {
          site.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
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
