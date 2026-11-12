import 'package:webspace/services/activation_step.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// The page as an activation sees it, recording what it tells the user.
final class FakeActivationPage implements ActivationHost, SurfaceHost {
  final toasts = <String Function(AppLocalizations)>[];
  var exitedFullscreen = false;

  /// Whether the page is in full screen, as the activation last told it.
  var fullscreen = false;

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
  void enterFullscreen() => fullscreen = true;

  @override
  void exitFullscreen() {
    exitedFullscreen = true;
    fullscreen = false;
  }

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

/// The residency of [sites] on the jar they hold.
final class FakeResidency implements ResidencyHost {
  FakeResidency(this.sites);

  final SiteRuntime sites;

  /// A test that needs a flow in flight sets [kindsInFlight].
  Set<FlowKind> kindsInFlight = {};

  @override
  bool flowInFlight(FlowKind kind) => kindsInFlight.contains(kind);

  @override
  WarmLimits get warmLimits => kWarmLimits;

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  List<WebViewModel> get models => sites.models;

  @override
  RuntimeVars<SiteId> get vars => sites.vars;

  @override
  WebViewModel siteOf(SiteId id) => sites.siteOf(id);

  @override
  Isolation get isolation => sites.isolation;

  @override
  NavCapture? beginNavCapture(SiteId site) => null;

  @override
  void noteUnloaded(SiteId site, {required UnloadReason reason}) {}

  @override
  SlotIdentities identities() => sites.slotIdentities();

  @override
  SiteRetentionPriority priorityOf(int index) =>
      sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => ProxyTopology.of(
      binding: ProxyBinding.perSite,
      sharesDefaultSession: (_) => false);

  @override
  bool get torAvailable => false;
}
