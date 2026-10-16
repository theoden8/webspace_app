import 'dart:typed_data';

import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/startup_controller.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

/// What [SiteActivationController] answers its flows: its own rules and
/// effects, which the flows reach through their `page` port.
typedef ActivationAnswers = ({
  Iterable<FlowKind> Function() kindsInFlight,
  ResidencyPlan Function(ResidencyEvent event) residencyPlan,
  void Function() leftForHome,
  void Function(WebViewModel site, {required int version}) afterResume,
  Future<void> Function(WebViewModel site, {required int version}) pause,
  NavCapture? Function(WebViewModel site) beginNavCapture,
  Future<void> Function(WebViewModel site) ensureSiteHtml,
  void Function(WebViewModel site) keepLoading,
});

/// What an activation's flow reaches of the controller that runs it: the
/// page's sites, its host, the residency rules, the stored back stacks and
/// the controller's answers. Built once by the controller.
typedef ActivationReach = ({
  SiteRuntime sites,
  ActivationHost host,
  ResidencyHost residency,
  WebViewStateStorage navStates,
  ActivationAnswers answers,
});

/// What an activation keeps for itself: the input's target, launch,
/// opening or webspaces left, the plan once made, the bytes the nav step
/// read, and what its calls answered. Code-only, none of it a variable of
/// the model.
abstract interface class ActivationState {
  WebViewModel? get target;
  Reached<Launched>? get launch;
  NestedRequest? get opening;
  Set<WebViewModel>? get leaving;
  abstract ResidencyPlan? plan;
  abstract Uint8List? navBytes;
  abstract bool committed;
  abstract bool refused;
  abstract bool online;
}

/// What the activation's steps ask of the page and the rules it runs,
/// through their `page` port, and the effects that change nothing the steps
/// do not write themselves.
final class ActivationCalls {
  ActivationCalls(this._r);

  final ActivationReach _r;

  WebViewModel? get shown => _r.sites.shown;
  List<WebViewModel> get models => _r.sites.models;
  Iterable<WebViewModel> get running => _r.sites.vars.running;
  Iterable<FlowKind> get kindsInFlight => _r.answers.kindsInFlight();
  bool isEvictable(WebViewModel site) => _r.sites.vars.isEvictable(site);
  WebViewModel? get liveTarget => _r.sites.vars.liveTarget;
  void keepLoading(WebViewModel site) => _r.answers.keepLoading(site);
  WebViewModel firstToEvict(List<WebViewModel> among) =>
      _r.sites.firstToEvict(among);
  List<WebViewModel> conflicts(WebViewModel site) =>
      SiteUnloadEngine.conflictsOf(_r.residency, site: site);
  List<WebViewModel> proxyContenders(WebViewModel site) =>
      SiteUnloadEngine.proxyContendersOf(_r.residency, site: site);
  List<WebViewModel> torDissenters(WebViewModel site) =>
      SiteUnloadEngine.torDissentersOf(_r.residency, site: site);
  ResidencyPlan residencyPlan(ResidencyEvent event) => _r.answers.residencyPlan(event);

  void forgetTabReturns() => _r.host.forgetTabReturns();
  Future<bool> isOnline() => _r.host.isOnline();
  void leftForHome() => _r.answers.leftForHome();

  /// [site] was not shown, since the jar refused its cookies (ISO-014).
  void cookiesNotRestored(WebViewModel site) =>
      _r.host.toast((loc) => loc.siteCookiesNotRestored(site.getDisplayName()));
  NavCapture? beginNavCapture(WebViewModel site) => _r.answers.beginNavCapture(site);
  Future<void> refreshRoutes({required WebViewModel active}) =>
      _r.host.refreshRoutes(active: active);
  Future<void> ensureSiteHtml(WebViewModel site) =>
      _r.answers.ensureSiteHtml(site);
  void rebuild() => _r.host.rebuild();
  void rebuildAndNoteBackground() => _r.host
    ..rebuild()
    ..backgroundSitesChanged();
  void afterResume(WebViewModel site, {required int version}) =>
      _r.answers.afterResume(site, version: version);

  /// [site]'s webview resumed, once the activation has committed.
  Future<void> resume(WebViewModel site) => site.resumeWebView();

  /// The site left stopped and paused (SiteTeardownEngine).
  Future<void> pause(WebViewModel site, {required int version}) =>
      _r.answers.pause(site, version: version);

  /// The Tor exit pin follows [site] and the loaded sites (TOR-014).
  void syncTorExitPin(WebViewModel site) {
    if (TorService.instance.isAvailable) {
      _r.host.syncTorExitPin({site, ..._r.sites.loaded});
    }
  }
}

final class ActivationFlow implements Capturing, ActivationState {
  ActivationFlow(
    this.reach, {
    required this.target,
    required this.launch,
    required this.opening,
    required this.leaving,
  });

  /// What the flow's steps reach of the controller that runs it, through
  /// its leaves and ports.
  final ActivationReach reach;

  /// What an activation keeps for itself ([ActivationState]): code-only,
  /// none of it the model's.
  static final state = Port<ActivationState, ActivationFlow>(
    'flow',
    reads: const {},
    changes: const {},
    of: (w) => w,
  );

  /// What the activation's steps ask of the page and the rules it runs
  /// ([ActivationCalls]), and the effects that change nothing the steps do
  /// not write themselves: the redraws, the teardown, the routes, the
  /// HTML snapshot, the Tor pin.
  static final page = Port<ActivationCalls, ActivationFlow>(
    'page',
    reads: const {},
    changes: const {},
    of: (w) => ActivationCalls(w.reach),
  );

  /// The site's state file read for its active tab, the model's `file`.
  static final files = Port<WebViewStateStorage, ActivationFlow>(
    'files',
    reads: {ModelVar.file},
    changes: const {},
    of: (w) => w.reach.navStates,
  );

  /// The site's state file read for a preload and queued as it lands,
  /// the model's `file` and `queued`.
  static final queue = Port<WebViewStateStorage, ActivationFlow>(
    'queue',
    reads: {ModelVar.file},
    changes: {ModelVar.queued},
    of: (w) => w.reach.navStates,
  );

  /// The site's container made or deleted, the model's `boxes`.
  static final boxes = Port<Isolation, ActivationFlow>(
    'boxes',
    reads: const {},
    changes: {ModelVar.boxes},
    of: (w) => w.reach.sites.isolation,
  );

  /// What the unload and restore tables nested here run against.
  static final nest = Port<
    ({ResidencyHost residency, Isolation isolation, RuntimeVars<WebViewModel> vars}),
    ActivationFlow
  >(
    'nest',
    reads: const {},
    changes: const {},
    of: (w) => (
      residency: w.reach.residency,
      isolation: w.reach.sites.isolation,
      vars: w.reach.sites.vars,
    ),
  );

  @override
  NavCapture? capture;

  /// The site the input names, for the input's own step to pick.
  @override
  final WebViewModel? target;

  /// The launch a preload runs in; no other input carries one.
  @override
  final Reached<Launched>? launch;

  /// The residency plan, from the plan step on.
  @override
  ResidencyPlan? plan;

  /// The back stack the nav step read, queued if the flow goes on; a
  /// preload's, queued as its read lands.
  @override
  Uint8List? navBytes;

  /// Whether the commit step ran: a preload's outcome.
  @override
  bool committed = false;

  /// What a nested open was asked for; no other input carries one.
  @override
  final NestedRequest? opening;

  /// Whether a nested open's proxy failed to apply.
  @override
  bool refused = false;

  /// What a webspace switch stops showing; no other input carries it.
  @override
  final Set<WebViewModel>? leaving;

  /// Whether the device answered that it is online, at a switch.
  @override
  bool online = true;
}
