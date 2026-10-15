import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/web_view_model.dart';

/// What a nested open asks of the page.
abstract interface class NestedLaunchHost implements PageHost {
  /// The page's one way to open a nested screen for a site (NESTED-010).
  Future<void> launchNestedFor(
    WebViewModel model, {
    required String url,
    bool opensFromTab = true,
  });
}

/// The page's side of a nested open: the screen, and the proxy it runs
/// under. Which sites go first, and when the screen goes up, is the
/// activation table's (`SiteActivationController.openNested`).
class NestedOpenBinding implements NestedScreenHost {
  NestedOpenBinding({
    required NestedLaunchHost host,
    required WebspacesController webspaces,
    required this.fromTab,
  }) : _host = host,
       _webspaces = webspaces;

  final NestedLaunchHost _host;
  final WebspacesController _webspaces;

  /// The screen opens over the tab on screen (outbound routing), not for a
  /// share, so a link in it can come back as a tab (LIR-032).
  final bool fromTab;

  @override
  Future<void> switchWebspaceFor(WebViewModel target) =>
      _webspaces.revealSite(target);

  // Android/Linux: the proxy is a process-global override, and the nested
  // screen is for a site that is not being activated, so its proxy is put in
  // force here or it would load through whatever the active site left
  // behind, bound to this site's container (LEAK-003). Under router mode the
  // rule points at the relay and this no-ops.
  @override
  Future<void> applyProxyOf(WebViewModel target) =>
      ProxyManager().setProxySettings(
        target.proxySettings,
        siteId: target.siteId,
        occupant: (use: RouteUse.nested, site: target.siteId),
      );

  @override
  void reportProxyFailure(Object error) {
    LogTag.proxy.error(
      'Nested open refused: proxy apply failed: $error',
      sensitive: true,
    );
    _host.toast((loc) => loc.siteSettingsProxyError('$error'));
  }

  @override
  Future<void> launch(WebViewModel target, {required String url}) async {
    if (!_host.mounted) return;
    await _host.launchNestedFor(target, url: url, opensFromTab: fromTab);
  }

  @override
  void closed(WebViewModel target) => ProcessRoute.instance.release(
    (use: RouteUse.nested, site: target.siteId),
  );
}
