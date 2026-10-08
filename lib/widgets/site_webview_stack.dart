import 'package:flutter/material.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/stats_banner.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';
import 'package:webspace/widgets/unproxied_block.dart';

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
  final WebViewHostHooks hooks;
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
  _SiteWebView({
    required this.site,
    required this.hooks,
    required this.showStatsBanner,
  }) : super(key: ValueKey(site.siteId));

  final WebViewModel site;
  final WebViewHostHooks hooks;
  final bool showStatsBanner;

  @override
  Widget build(BuildContext context) {
    // The HTML cache is a snapshot of the site's own page; a hosted tab
    // neither reads nor writes it (LIR-018).
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
              // file:// imports are user data, the only copy on the device,
              // not a re-fetchable snapshot, so they skip the save path.
              onHtmlLoaded: htmlSource != HtmlSource.cache
                  ? null
                  : (url, {required html}) => HtmlCacheService.instance.saveHtml(
                      site.siteId,
                      html: html,
                      url: url,
                    ),
              // Skips the per-onLoadStop snapshot IPC into chromium when a
              // save would be debounced anyway: every SPA pseudo-navigation
              // serialized the renderer DOM, each a candidate for racing
              // chromium's frame-lifecycle teardown. Archive-tier sites skip
              // the cache write entirely (ARCH-006).
              shouldFetchHtml: htmlSource != HtmlSource.cache
                  ? null
                  : () => HtmlCacheService.instance.shouldSave(site.siteId),
              initialHtml: htmlSource == HtmlSource.none
                  ? null
                  : _initialHtml(context, isFileImport: htmlSource == HtmlSource.import),
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
    final blocked = site.blockedNavigationUrl;
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
              blockedUrl: blocked,
              onGoBack: () {
                site.blockedNavigationUrl = null;
                hooks.rebuild();
              },
              onOpenProxySettings: () => hooks.openSiteSettings(site.siteId),
            ),
          ),
      ],
    );
  }

  /// The first paint, before the live load swaps in (the factory's
  /// `pendingLiveReload` skips the swap offline). A file:// import renders
  /// its stored bytes, having no live page. A URL site reads its cache only
  /// with `htmlCachingEnabled` or when offline at construction, so an online
  /// cold start never shows stale content.
  String? _initialHtml(BuildContext context, {required bool isFileImport}) {
    if (!isFileImport &&
        !site.htmlCachingEnabled &&
        (ConnectivityService.instance.lastKnownOnline ?? true)) {
      return null;
    }
    final cached = isFileImport
        ? HtmlImportStorage.instance.getHtmlSync(site.siteId)
        : HtmlCacheService.instance.getHtmlSync(site.siteId);
    if (cached == null) return null;
    final isDark =
        site.currentTheme == WebViewTheme.dark ||
        (site.currentTheme == WebViewTheme.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    return HtmlCacheService.applyThemePrelude(cached, dark: isDark);
  }
}
