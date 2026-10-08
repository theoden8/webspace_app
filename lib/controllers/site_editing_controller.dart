import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/page_title.dart';
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
}

/// What the site editing flows ask of the page.
abstract interface class SiteEditingHost implements PageHost {
  Future<void> activate(int? index);
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
  }) : _host = host,
       _prompts = prompts,
       _shell = shell,
       _shortcuts = shortcuts;

  final SiteRuntime _sites;
  final SiteEditingHost _host;
  final SiteEditingPrompts _prompts;
  final ShellStore _shell;
  final ShortcutController _shortcuts;

  /// Adds [model] to the selected named webspace too, persists, and with
  /// [activate] puts it on screen. Pass false when the app, not the user,
  /// chose to create it: an unattended entry point must not put a stranger's
  /// page on screen.
  Future<void> registerSite(WebViewModel model, {bool activate = true}) async {
    // Before the first build: initialHtml reads currentTheme to pick the dark
    // prelude for cached HTML (file:// imports especially, which never reload
    // to live), and the model defaults to WebViewTheme.light.
    await model.setTheme(_shell.theme.themeMode.webViewTheme);
    await _host.commitSites(SiteAdded(model));
    if (!activate || !_host.mounted) return;
    await _host.activate(_sites.models.indexOf(model));
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
      // go into HtmlImportStorage (persistent) rather than HtmlCacheService
      // (cleared on app upgrade). The webview reads from the import store
      // for `initialHtml` on creation.
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

  Future<void> editSite(int index) async {
    final model = _sites.models[index];
    final result = await _prompts.editSite(model);
    if (result == null || !_host.mounted) return;
    // Apply by the captured model identity, not the index: a concurrent
    // delete of a lower-indexed site while the dialog was open shifts
    // positions, so `index` could now target a different site. Bail if this
    // model was deleted meanwhile.
    if (!_sites.models.contains(model)) return;

    final (:name, :url, :icon) = result;
    if (icon != null) model.customIconPng = icon.png;
    if (name.isNotEmpty) model.name = name;
    if (icon != null || name.isNotEmpty) _host.rebuild();

    if (url != model.initUrl) {
      // Snapshot belongs to the old URL; deleteCache must run before the
      // rebuild's getHtmlSync, which is why the sync in-memory eviction
      // (inside deleteCache) is fired before the rebuild rather than awaited.
      final siteId = model.siteId;
      final deleteCache = HtmlCacheService.instance.deleteCache(siteId);
      model.initUrl = url;
      model.currentUrl = url;
      model.webview = null; // Force recreation with new URL
      model.controller = null;
      _host.rebuild();
      await deleteCache;
    }

    await _host.commitSites(const SitesEdited());
  }

  Future<void> deleteSite(int index) async {
    final confirmed = await _prompts.confirmDelete(_sites.models[index]);

    if (confirmed != true || !_host.mounted) return;
    if (index >= _sites.models.length) return;

    final deletedModel = _sites.models[index];
    // HS-013: the tiles reaching the site, read before it goes.
    final reachingTiles = await _shortcuts.tilesReaching(deletedModel);
    if (!_host.mounted) return;
    await _host.commitSites(SiteRemoved(deletedModel));
    await _shortcuts.siteDeleted(deletedModel, tiles: reachingTiles);

    if (!_host.mounted) return;
    // closeDrawer() (not Navigator.pop): the drawer tile the menu came from
    // is the site just removed, and the close is idempotent, like the other
    // drawer taps.
    _host.closeDrawer();
  }
}
