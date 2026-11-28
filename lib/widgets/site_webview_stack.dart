import 'package:flutter/material.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_hooks.dart';
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
    required this.onFrame,
  });

  final List<WebViewModel> models;
  final Set<int> loaded;
  final int? current;
  final SiteHooks hooks;
  final bool showStatsBanner;

  /// Told as a site's webview mounts and as it unmounts, the frame's step
  /// (`Frame`).
  final void Function(WebViewModel site) onFrame;

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
            onFrame: onFrame,
          )
        else
          const SizedBox.shrink(),
    ],
  );
}

class _SiteWebView extends StatefulWidget {
  // Keyed globally, so a delete or move that shifts this site's row takes its
  // webview along: IndexedStack wraps each child in an unkeyed Visibility, so
  // a local key never meets its old element (ISO-009).
  _SiteWebView({
    required this.site,
    required this.hooks,
    required this.showStatsBanner,
    required this.onFrame,
  }) : super(key: GlobalObjectKey(site));

  final WebViewModel site;
  final SiteHooks hooks;
  final bool showStatsBanner;
  final void Function(WebViewModel site) onFrame;

  @override
  State<_SiteWebView> createState() => _SiteWebViewState();
}

/// A site's slot as the frame mounts and unmounts it: each tells the frame's
/// step (`Frame`).
class _SiteWebViewState extends State<_SiteWebView> {
  @override
  void initState() {
    super.initState();
    widget.onFrame(widget.site);
  }

  @override
  void dispose() {
    widget.onFrame(widget.site);
    super.dispose();
  }

  WebViewModel get site => widget.site;
  SiteHooks get hooks => widget.hooks;

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
          if (widget.showStatsBanner)
            StatsBanner(
              siteId: site.siteId,
              dnsBlockEnabled: site.dnsBlockEnabled,
            ),
          Expanded(
            // The site's warm views stay mounted, hidden and paused, so a
            // switch back shows one as it was (TAB-023). Each is globally
            // keyed, so it moves between here and the shown place whole.
            // Offstage alone leaves a hidden page in Tab's way.
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (final warm in site.warmViews.values)
                  if (warm.webview case final view?)
                    Offstage(
                      child: ExcludeFocus(
                        child: TickerMode(enabled: false, child: view),
                      ),
                    ),
                _withInterstitial(site.getWebView(
                  hooks,
                  cacheFirst: loadsCacheFirst(htmlSource,
                      htmlCaching: site.htmlCachingEnabled,
                      online: ConnectivityService.instance.lastKnownOnline,
                      engineCan: engineLoadsCacheFirst),
                  initialHtml: htmlSource == HtmlSource.import
                      ? _importedHtml(context)
                      : null,
                )),
              ],
            ),
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
    final told =
        site.effectiveTheme.under(MediaQuery.platformBrightnessOf(context));
    return HtmlImportStorage.applyThemePrelude(cached,
        dark: told == Brightness.dark);
  }
}
