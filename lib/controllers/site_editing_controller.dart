import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/redirect_domain_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart' show SiteEdit;

/// What the site editing flows ask the user.
abstract interface class SiteEditingPrompts {
  /// The add-site screen's answer: a map with `url`, `name`, `incognito` and
  /// `htmlContent`, or with `qrSettings` from the scanner; null when closed.
  Future<Object?> addSite({String? initialUrl});

  /// Mandatory review of a QR-borne site configuration before it is created
  /// (QR-008).
  Future<bool> reviewQrSettings(Map<String, dynamic> qr);

  Future<SiteEdit?> editSite(WebViewModel site);
  Future<bool> confirmDelete(WebViewModel site);
  Future<bool> addRedirectDomain(DomainClaim claim);
}

/// What the site editing flows ask of the page.
abstract interface class SiteEditingHost implements PageHost {
  Future<void> activate(WebViewModel? site);
  void closeDrawer();
}

/// Adding, editing and deleting a site.
class SiteEditingController {
  SiteEditingController(
    this._sites, {
    required SiteEditingHost host,
    required SiteEditingPrompts prompts,
    required ShellStore shell,
    required ShortcutController shortcuts,
    required SiteDeletion deletion,
  }) : _host = host,
       _prompts = prompts,
       _shell = shell,
       _shortcuts = shortcuts,
       _deletion = deletion;

  final SiteRuntime _sites;
  final SiteEditingHost _host;
  final SiteEditingPrompts _prompts;
  final ShellStore _shell;
  final ShortcutController _shortcuts;
  final SiteDeletion _deletion;
  final _redirectDomainGuard = ReentryGuard();

  /// A first live page reached an unclaimed domain. Remember showing the
  /// question, and change routing only after its explicit Add action.
  Future<void> offerRedirectDomain(WebViewModel source, {required String url}) async {
    await _redirectDomainGuard.run(() async {
      if (!_host.mounted || !_sites.fore || !identical(_sites.shown, source) ||
          !_sites.models.contains(source) || source.runsForeignTab ||
          source.currentUrl != url) {
        return;
      }
      final site = source.runningIdentity;
      if (!_sites.models.contains(site)) return;
      final resolved = Uri.tryParse(url);
      if (resolved == null) return;
      DomainClaim? candidate() => redirectDomainClaim(SiteRoute(site),
          resolvedUrl: resolved, sites: _sites.models.map(SiteRoute.new).toList());
      final claim = candidate();
      if (claim == null || !site.offeredRedirectDomains.add(claim)) return;
      final home = site.initUrl;
      final accepted = await _prompts.addRedirectDomain(claim);
      if (!_host.mounted || !_sites.models.contains(site)) return;
      if (accepted && site.initUrl == home && identical(_sites.shown, source) &&
          identical(source.runningIdentity, site) && candidate() == claim) {
        site.domainClaims = LinkRoutingService.mergeClaims(site.effectiveDomainClaims,
            additions: [claim]);
      }
      await _host.commitSites(const SitesEdited());
    });
  }

  /// Adds [model] to the selected named webspace too, persists, and with
  /// [activate] puts it on screen. Pass false when the app, not the user,
  /// chose to create it: an unattended entry point must not put a stranger's
  /// page on screen.
  Future<void> registerSite(WebViewModel model, {bool activate = true}) async {
    // Before the first build: initialHtml reads effectiveTheme to pick the dark
    // prelude for a file:// import, which never reloads to live, and the model
    // defaults to WebViewTheme.light.
    await model.setAppTheme(_shell.theme.themeMode.webViewTheme);
    await _host.commitSites(SiteAdded(model));
    if (!activate || !_host.mounted) return;
    await _host.activate(model);
    if (!_host.mounted) return;
    _host.rebuild();
    await _shell.saveCurrentIndex();
  }

  /// [deepLinkQrSettings] is a decoded `webspace://qr/` payload that arrived
  /// from outside the app. Both QR entry points (this one and the in-app
  /// scanner, which returns `{'qrSettings': ...}` from `AddSiteScreen`) pass
  /// through the same review gate below, and a payload the app did not ask
  /// for never becomes the visible site.
  Future<void> addSite({
    String? initialUrl,
    Map<String, dynamic>? deepLinkQrSettings,
  }) async {
    Object? result;
    if (deepLinkQrSettings != null) {
      result = {'qrSettings': deepLinkQrSettings};
    } else {
      result = await _prompts.addSite(initialUrl: initialUrl);
    }
    if (result == null || result is! Map<String, dynamic>) return;
    if (!_host.mounted) return;

    final stateSetter = _host.rebuild;
    late WebViewModel model;
    final resultQrSettings = result['qrSettings'] as Map<String, dynamic>?;

    if (resultQrSettings != null) {
      final accepted = await _prompts.reviewQrSettings(resultQrSettings);
      if (!accepted || !_host.mounted) return;
      model = WebViewModel.fromJson(
        SiteSettingsQrCodec.hydrateForFromJson(resultQrSettings),
        stateSetterF: stateSetter,
      );
      if (model.name.isEmpty) {
        final pageTitle = await getPageTitle(
          model.initUrl,
          proxy: model.outboundProxySettings,
        );
        if (!_host.mounted) return;
        if (pageTitle != null && pageTitle.isNotEmpty) {
          model.name = pageTitle;
          model.pageTitle = pageTitle;
        }
      } else {
        model.pageTitle = model.name;
      }
    } else {
      final url = result['url'] as String;
      final customName = result['name'] as String;
      final incognito = result['incognito'] as bool? ?? false;
      final htmlContent = result['htmlContent'] as String?;

      // Try to fetch page title if custom name not provided (skip for local files)
      String? pageTitle;
      if (customName.isEmpty && htmlContent == null) {
        pageTitle = await getPageTitle(url);
        if (!_host.mounted) return;
      }

      model = WebViewModel(
        initUrl: url,
        incognito: incognito,
        stateSetterF: stateSetter,
      );
      if (customName.isNotEmpty) {
        model.name = customName;
        model.pageTitle = customName;
      } else if (pageTitle != null && pageTitle.isNotEmpty) {
        model.name = pageTitle;
        model.pageTitle = pageTitle;
      }

      // Imported HTML files are the only copy of the user's data, so they
      // go into HtmlImportStorage, which survives upgrades. The webview
      // reads from it for `initialHtml` on creation.
      if (htmlContent != null && !incognito) {
        await HtmlImportStorage.instance.saveHtml(
          model.siteId,
          html: htmlContent,
          url: url,
        );
      }
    }

    await registerSite(model, activate: deepLinkQrSettings == null);
  }

  Future<void> editSite(WebViewModel model) async {
    final result = await _prompts.editSite(model);
    if (result == null || !_host.mounted) return;
    // Deleted while the dialog was open.
    if (!_sites.models.contains(model)) return;

    final (:name, :url, :icon) = result;
    if (icon != null) model.customIconPng = icon.png;
    if (name.isNotEmpty) model.name = name;
    if (icon != null || name.isNotEmpty) _host.rebuild();

    if (url != model.initUrl) {
      model.initUrl = url;
      model.currentUrl = url;
      model.webview = null; // Force recreation with new URL
      model.controller = null;
      _host.rebuild();
    }

    await _host.commitSites(const SitesEdited());
  }

  /// Deletes the site the user confirmed, wherever it sits by then: a row
  /// read after the dialog could name another site.
  Future<void> deleteSite(WebViewModel deletedModel) async {
    final confirmed = await _prompts.confirmDelete(deletedModel);

    if (confirmed != true || !_host.mounted) return;
    if (!_sites.models.contains(deletedModel)) return;
    // HS-013: the tiles reaching the site, read before it goes.
    final reachingTiles = await _shortcuts.tilesReaching(deletedModel);
    if (!_host.mounted) return;
    await _deletion.delete(deletedModel);
    await _shortcuts.siteDeleted(deletedModel, tiles: reachingTiles);

    if (!_host.mounted) return;
    // closeDrawer() (not Navigator.pop): the drawer tile the menu came from
    // is the site just removed, and the close is idempotent, like the other
    // drawer taps.
    _host.closeDrawer();
  }
}
