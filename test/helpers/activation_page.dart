import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/web_view_model.dart';

/// The page as an activation sees it, recording what it tells the user.
final class FakeActivationPage implements ActivationHost, SurfaceHost {
  final toasts = <String Function(AppLocalizations)>[];
  var exitedFullscreen = false;

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) =>
      toasts.add(message);

  @override
  Future<void> commitSites(SiteSetChange change) async {}

  @override
  void forgetTabReturns() {}

  @override
  void enterFullscreen() {}

  @override
  void exitFullscreen() => exitedFullscreen = true;

  @override
  Future<void> refreshRoutes({WebViewModel? active}) async {}

  @override
  Future<bool> isOnline() async => true;

  @override
  Future<void> spawned(Future<void> Function() flow) => flow();

  @override
  void syncTorExitPin(Iterable<WebViewModel> sites) {}

  @override
  Future<void> probeRenderer(WebViewModel model,
      {required String trigger}) async {}

  @override
  void backgroundSitesChanged() {}
}

/// The residency of [sites] on the isolation they hold, with no proxy
/// router and no Tor.
final class FakeResidency implements ResidencyHost {
  FakeResidency(this.sites);

  final SiteRuntime sites;

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  List<WebViewModel> get models => sites.models;

  @override
  RuntimeVars<WebViewModel> get vars => sites.vars;

  @override
  Isolation get isolation => sites.isolation;

  @override
  NavCapture? beginNavCapture(WebViewModel model) => null;

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) {}

  @override
  List<WebViewModel> identities({int? except}) =>
      sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
      linux: false,
      android: false,
      routerActive: false,
      sharesDefaultSession: (_) => false);

  @override
  bool get torAvailable => false;
}
