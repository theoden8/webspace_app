import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/web_view_model.dart';

/// What the host answers for a site's own webview: [host]'s answers, which
/// every webview that runs as a site takes, and those that name the site
/// itself, which only its own webview asks.
final class SiteHooks {
  const SiteHooks({
    required this.host,
    required this.onScreen,
    required this.routeOutbound,
    required this.linkMenu,
    required this.firstPageLoaded,
  });

  final WebViewHostHooks host;

  /// Whether [slot] is the site on screen: a background site opens nothing
  /// nested and gets no device capture (MIC-014).
  final bool Function(WebViewModel slot) onScreen;

  /// [source]'s webview is about to nest, send out or block [url]: true when
  /// the host took the link over (LIR-014, NESTED-009).
  final bool Function(WebViewModel source,
      {required String url,
      required NavigationDecision decision,
      required bool hadGesture}) routeOutbound;

  /// A long-press on a link in [source]'s webview (TAB-006). The site, not
  /// its row: the list can have been reordered by the time the native event
  /// lands.
  final Future<void> Function(WebViewModel source, {required String url})
      linkMenu;

  /// Offers an unclaimed domain reached by this slot's first live page.
  final Future<void> Function(WebViewModel source, {required String url})
      firstPageLoaded;
}
