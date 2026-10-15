import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/web_view_model.dart';

/// What activation asks of the page's other controllers.
abstract interface class ActivationHost implements PageHost {
  /// Another site by any way leaves the Tabs sheet's way back behind
  /// (TAB-019).
  void forgetTabReturns();

  void enterFullscreen();
  void exitFullscreen();

  Future<void> refreshRoutes({WebViewModel? active});

  /// Whether the device reaches the network, which a webspace switch asks
  /// before it unloads anything (WEBSPACE-013).
  Future<bool> isOnline();

  /// Runs [flow], an activation the controller starts beside the input that
  /// spawned it: the page runs it as is, and the walks run it as a flow of
  /// its own, which only this seam lets them number.
  Future<void> spawned(Future<void> Function() flow);

  /// Puts in force the exit pin [sites] want, the first deciding (TOR-014).
  void syncTorExitPin(Iterable<WebViewModel> sites);

  /// Probes [model]'s renderer and recovers a dead or blank one.
  Future<void> probeRenderer(WebViewModel model, {required String trigger});

  /// The loaded sites changed: the background refresh schedule and the iOS
  /// audio session follow.
  void backgroundSitesChanged();
}

/// What a nested open asks of the page (LIR-011, LIR-015): the screen it
/// pushes for a site and the proxy that screen runs under.
abstract interface class NestedScreenHost {
  /// WEBSPACE-012: the webspace that shows [target].
  Future<void> switchWebspaceFor(WebViewModel target);

  /// Points the process-wide proxy at [target]'s route; throws
  /// [ProxyRefused] when it cannot.
  Future<void> applyProxyOf(WebViewModel target);

  void reportProxyFailure(Object error);

  /// Pushes the screen running as [target] at [url]; completes when it pops.
  Future<void> launch(WebViewModel target, {required String url});

  /// The screen [target] ran as is gone, and what it ran on with it.
  void closed(WebViewModel target);
}

/// A nested open's request: the screen's host, the page it opens, and the
/// site a routed link came from, which comes back once the screen pops.
typedef NestedRequest = ({
  NestedScreenHost screen,
  String url,
  WebViewModel? source,
});
