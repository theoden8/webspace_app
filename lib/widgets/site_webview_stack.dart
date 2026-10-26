import 'package:flutter/material.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_hooks.dart';
import 'package:webspace/widgets/stats_banner.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';
import 'package:webspace/widgets/unproxied_block.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// One webview per loaded site, the one at [current] showing. A slot that is
/// not loaded holds an empty box, so positions line up with [models] and a
/// site's webview State survives switching away from it.
class SiteWebViewStack extends StatelessWidget {
  const SiteWebViewStack({
    super.key,
    required this.models,
    required this.loaded,
    required this.current,
    required this.hooks,
    required this.showStatsBanner,
  });

  final List<WebViewModel> models;
  final Set<int> loaded;
  final int? current;
  final SiteHooks hooks;
  final bool showStatsBanner;

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: current ?? 0,
    children: [
      for (final (index, site) in models.indexed)
        if (loaded.contains(index))
          _SiteWebView(
            site: site,
            hooks: hooks,
            showStatsBanner: showStatsBanner,
          )
        else
          const SizedBox.shrink(),
    ],
  );
}

class _SiteWebView extends StatelessWidget {
  // Keyed globally, so a delete or move that shifts this site's row takes its
  // webview along: IndexedStack wraps each child in an unkeyed Visibility, so
  // a local key never meets its old element (ISO-009).
  _SiteWebView({
    required this.site,
    required this.hooks,
    required this.showStatsBanner,
  }) : super(key: GlobalObjectKey(site));

  final WebViewModel site;
  final SiteHooks hooks;
  final bool showStatsBanner;

  @override
  Widget build(BuildContext context) {
    // The site's own page is what its cache holds; a hosted tab opens
    // another page, live (LIR-018).
    final htmlSource = site.runsHostedTab || site.runsForeignTab
        ? HtmlSource.none
        : htmlSourceFor(
            incognito: site.incognito,
            isArchiveTier: site.isArchiveTier,
            initUrl: site.initUrl,
          );
    return SizedBox.expand(
      child: Column(
        children: [
          if (showStatsBanner)
            StatsBanner(
              siteId: site.siteId,
              dnsBlockEnabled: site.dnsBlockEnabled,
            ),
          Expanded(
            child: _withInterstitial(site.getWebView(
              hooks,
              cacheFirst: loadsCacheFirst(htmlSource,
                  htmlCaching: site.htmlCachingEnabled,
                  online: ConnectivityService.instance.lastKnownOnline,
                  engineCan: engineLoadsCacheFirst),
              initialHtml: htmlSource == HtmlSource.import
                  ? _importedHtml(context)
                  : null,
            )),
          ),
        ],
      ),
    );
  }

  /// [webView], or the Tor placeholder while it waits (TOR-008), under the
  /// interstitial for a navigation its proxy could not cover (LEAK-010).
  Widget _withInterstitial(Widget? webView) {
    if (webView == null) return const TorBootstrapPlaceholder();
    final blocked = site.blockedNavigation;
    // Always the same Stack, whether or not the interstitial is in it: a
    // widget swapped in at this slot would unmount the platform view and
    // take the page the user is still on with it. `StackFit.expand` keeps
    // the webview's constraints exactly what they were without it.
    //
    // Over the webview rather than instead of it, because the navigation was
    // cancelled: the document underneath is live, and dismissing the
    // interstitial is what "go back" means here.
    return Stack(
      fit: StackFit.expand,
      children: [
        webView,
        if (blocked != null)
          Positioned.fill(
            child: UnproxiedNavigationBlock(
              siteName: site.name,
              blocked: blocked,
              onGoBack: () {
                site.blockedNavigation = null;
                hooks.host.rebuild();
              },
              onOpenProxySettings: () => hooks.host.openSiteSettings(site.siteId),
            ),
          ),
      ],
    );
  }

  /// A file:// import's stored bytes, which it renders, having no live page.
  String? _importedHtml(BuildContext context) {
    final cached = HtmlImportStorage.instance.getHtmlSync(site.siteId);
    if (cached == null) return null;
    final isDark = switch (site.effectiveTheme) {
      WebViewTheme.dark => true,
      WebViewTheme.light => false,
      WebViewTheme.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    return HtmlImportStorage.applyThemePrelude(cached, dark: isDark);
  }
}
