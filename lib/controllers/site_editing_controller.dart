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
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart' show SiteEdit;

/// What the site editing flows ask the user.
/// The add-site screen's answer, a map with `url`, `name`, `incognito` and
/// `htmlContent`, or with `qrSettings` from the scanner; and the named
/// webspaces picked there for the new site, null where none were offered.
typedef SiteAddition = ({Map<String, dynamic> site, Set<WebspaceId>? spaces});

abstract interface class SiteEditingPrompts {
  /// [spaces] are the named webspaces the new site may join and [picked]
  /// those it starts in; [existingUrls] the homes of the sites already
  /// added; null when closed.
  Future<SiteAddition?> addSite({
    String? initialUrl,
    required List<Webspace> spaces,
    required Set<WebspaceId> picked,
    required List<String> existingUrls,
  });

  /// Mandatory review of a QR-borne site configuration before it is created
  /// (QR-008).
  Future<bool> reviewQrSettings(Map<String, dynamic> qr);

  /// [spaces] are the named webspaces the user may put the site in.
  Future<SiteEdit?> editSite(WebViewModel site,
      {required List<Webspace> spaces});
  Future<bool> confirmDelete(WebViewModel site);
  Future<bool> updateRedirectHome(String url);
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
  final _redirectHomeGuard = ReentryGuard();

  /// Keep the loaded page while saving its redirected address as the home.
  Future<void> offerRedirectHome(WebViewModel source, {required String url}) async {
    await _redirectHomeGuard.run(() async {
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
          resolvedUrl: resolved,
          navigationDecision: site.decideUserOpenedLink(url, isActive: true),
          sites: _sites.models.map(SiteRoute.new).toList());
      final claim = candidate();
      if (claim == null || !site.offeredRedirectDomains.add(claim)) return;
      final home = site.initUrl;
      final accepted = await _prompts.updateRedirectHome(url);
      if (!_host.mounted || !_sites.models.contains(site)) return;
      if (accepted && _sites.fore && site.initUrl == home &&
          identical(_sites.shown, source) && source.currentUrl == url &&
          !source.runsForeignTab && identical(source.runningIdentity, site) &&
          candidate() == claim) {
        site.domainClaims = LinkRoutingService.mergeClaims(site.effectiveDomainClaims,
            additions: [claim]);
        site.initUrl = url;
      }
      await _host.commitSites(const SitesEdited());
    });
  }

  /// Adds [model] to the selected named webspace too, persists, and with
  /// [activate] puts it on screen. Pass false when the app, not the user,
  /// chose to create it: an unattended entry point must not put a stranger's
  /// page on screen.
  /// [joins] are the named webspaces [model] joins; null joins the selected
  /// one.
  Future<void> registerSite(WebViewModel model,
      {bool activate = true, Set<WebspaceId>? joins}) async {
    // Before the first build: initialHtml reads effectiveTheme to pick the dark
    // prelude for a file:// import, which never reloads to live, and the model
    // defaults to WebViewTheme.light.
    await model.setAppTheme(_shell.theme.themeMode.webViewTheme);
    await _host.commitSites(SiteAdded(model, joins: joins));
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
  /// for never becomes the visible site. [into] is the webspace the site is
  /// added from, which the screen starts it in (EDIT-012).
  Future<void> addSite({
    String? initialUrl,
    Map<String, dynamic>? deepLinkQrSettings,
    WebspaceId? into,
  }) async {
    final SiteAddition? addition;
    if (deepLinkQrSettings != null) {
      addition = (site: {'qrSettings': deepLinkQrSettings}, spaces: null);
    } else {
      addition = await _prompts.addSite(
        initialUrl: initialUrl,
        spaces: [for (final ws in _sites.webspaces) if (!ws.isAll) ws],
        picked: {if (into != null && into != WebspaceId.all) into},
        existingUrls: [for (final site in _sites.models) site.initUrl],
      );
    }
    if (addition == null || !_host.mounted) return;
    final result = addition.site;

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
          proxy: model.outboundProxy,
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

    await registerSite(model,
        activate: deepLinkQrSettings == null, joins: addition.spaces);
  }

  Future<void> editSite(WebViewModel model) async {
    final result = await _prompts.editSite(model,
        spaces: [for (final ws in _sites.webspaces) if (!ws.isAll) ws]);
    if (result == null || !_host.mounted) return;
    // Deleted while the dialog was open.
    if (!_sites.models.contains(model)) return;

    final (:name, :url, :icon, :spaces) = result;
    final joinedOrLeft = spaces != null &&
        WebspaceSelectionEngine.setSiteMembership(_sites.webspaces,
            site: model.siteId, spaces: spaces);
    if (icon != null) model.customIconPng = icon.png;
    if (name.isNotEmpty) model.name = name;
    if (icon != null || name.isNotEmpty) _host.rebuild();

    if (url != model.initUrl) {
      model.initUrl = url;
      model.currentUrl = url;
      model.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
      _host.rebuild();
    }

    await _host.commitSites(const SitesEdited());
    if (joinedOrLeft) await _shell.saveWebspaces();
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
