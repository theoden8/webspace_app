import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/nested_open_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
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

/// Binds [NestedOpenEngine] to the page.
class NestedOpenBinding implements NestedOpenHost<WebViewModel> {
  NestedOpenBinding(
    this._sites, {
    required NestedLaunchHost host,
    required WebspacesController webspaces,
    required SiteActivationController activation,
    required this.fromTab,
  }) : _host = host,
       _webspaces = webspaces,
       _activation = activation;

  final SiteRuntime _sites;
  final NestedLaunchHost _host;
  final WebspacesController _webspaces;
  final SiteActivationController _activation;

  /// The screen opens over the tab on screen (outbound routing), not for a
  /// share, so a link in it can come back as a tab (LIR-032).
  final bool fromTab;

  @override
  bool get mounted => _host.mounted;

  // Android/Linux: the proxy is a process-global override that only the
  // activation path flips. The nested screen is for a site that is not
  // being activated, so the PROXY-008 sequence runs for it here or it would
  // load through whatever the active site left behind, bound to this site's
  // container (LEAK-003).
  //
  // Under router mode the eviction set is computed router-aware below: the
  // rule points at the relay for every site and the nested screen presents
  // this site's own credential, so `setProxySettings` no-ops and evicting
  // siblings would only cold-start what PROXY-013 keeps loaded.
  @override
  bool get proxyIsProcessGlobal => hostIsAndroid || hostIsLinux;

  @override
  int indexOf(WebViewModel site) => _sites.models.indexOf(site);

  @override
  int? get currentIndex => _sites.current;

  @override
  Future<void> switchWebspaceFor(WebViewModel target) async {
    final index = _sites.models.indexOf(target);
    if (index < 0) return;
    await _webspaces.revealSite(target, index: index);
  }

  @override
  Set<int> mismatchedWith(WebViewModel target) => {
    for (final unload
        in _activation
            .residencyPlan(NestedOpening(_sites.models.indexOf(target)))
            .unloads)
      _sites.models.indexOf(unload.site),
  };

  @override
  Future<void> unload(int index) =>
      _activation.unload(index, reason: UnloadReason.proxyMismatch);

  @override
  Future<void> applyProxyOf(WebViewModel target) => ProxyManager()
      .setProxySettings(target.proxySettings, siteId: target.siteId);

  @override
  void reportProxyFailure(Object error) {
    LogTag.proxy.error(
      'Nested open refused: proxy apply failed: $error',
      sensitive: true,
    );
    _host.toast((loc) => loc.siteSettingsProxyError('$error'));
  }

  @override
  Future<void> launchNested(WebViewModel target, {required String url}) =>
      _host.launchNestedFor(target, url: url, opensFromTab: fromTab);

  @override
  Future<void> activate(int index) => _activation.setCurrentIndex(index);
}
