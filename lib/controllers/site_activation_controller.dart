import 'dart:async';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/controllers/activation_flow.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/activation_place.dart';
import 'package:webspace/controllers/activation_table.dart';
import 'package:webspace/controllers/site_nav_capture.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/startup_controller.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_teardown_engine.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/utils/concurrency.dart';
import 'package:webspace/web_view_model.dart';

/// Which site is on screen, and what moves with it: the site coming on is
/// restored, isolated and resumed, the one leaving is quiesced, and the
/// loaded sites are trimmed to the ones that may stay.
class SiteActivationController {
  SiteActivationController(
    this._sites, {
    required ActivationHost host,
    required ResidencyHost residency,
    required WebViewStateStorage navStates,
    required SurfaceRepaintController surface,
  }) : _host = host,
       _residency = residency,
       _navStates = navStates,
       _surface = surface;

  final SiteRuntime _sites;
  final ActivationHost _host;
  final ResidencyHost _residency;
  final WebViewStateStorage _navStates;

  /// What this controller's flows reach of it ([ActivationFlow.reach]).
  late final ActivationReach _reach = (
    sites: _sites,
    host: _host,
    residency: _residency,
    navStates: _navStates,
    answers: (
      kindsInFlight: () => _kindsInFlight,
      residencyPlan: residencyPlan,
      leftForHome: _leftForHome,
      afterResume: _afterResume,
      pause: (site, {required version}) =>
          _teardown(site, version: version, steps: _pauseSteps(site)),
      beginNavCapture: beginNavCapture,
      ensureSiteHtml: ensureSiteHtmlForModel,
      keepLoading: _keepLoading,
    ),
  );
  final SurfaceRepaintController _surface;

  /// The flows in flight, each started by one input: the model's `fl`, read
  /// by the inputs' guards as the kinds among them (`Kinds`).
  final Set<StepContext<ActivationFlow>> _flows = {};

  Iterable<FlowKind> get _kindsInFlight => [
    for (final f in _flows)
      if (ActivationTable.kind.isSet(f)) ActivationTable.kind.of(f),
  ];

  /// Trims one loaded site per OS memory-pressure event (PAUSE-016), and
  /// probes the site on screen on every event, which the event itself can
  /// blank whether or not anything is evicted. An event while one is still
  /// applying its plan is dropped (the pressure step): two would pick the
  /// same victim and apply the same transition twice.
  Future<void> memoryPressure() async {
    final flow = _flow(target: null);
    final left = await _runFlow(flow, from: ActivationPlace.pressure);
    final plan = flow.world.plan;
    if (left == ActivationPlace.done && plan != null && !plan.isEmpty) {
      assert(
        _sites.activating != null ||
            _sites.shown == null ||
            _sites.loaded.contains(_sites.shown),
        'memory pressure unloaded the site on screen (PAUSE-006)',
      );
      if (plan.unloads.isNotEmpty) {
        // The pin in force follows the loaded sites (TOR-014). Left for the
        // next activation, the pin of a site evicted here was cleared at
        // whatever moment that came, often after a long suspension had cost
        // the control socket.
        _host.syncTorExitPin({?_sites.shown, ..._sites.loaded});
      }
      _host.rebuild();
    }

    // The pressure event itself, not our eviction, can blank the VISIBLE
    // site: iOS may jettison its frontmost WKWebView's content process, and
    // the Android hybrid-composition SurfaceView can drop its buffer under a
    // low-memory GL reclaim, most of all when it is the only site loaded and
    // nothing is evicted. The active site is hard-protected from eviction,
    // so neither the promotion above nor `activate` runs against it, and it
    // would otherwise stay blank until the next navigation. Probe + nudge it
    // on every event, covering both outcomes: a dead renderer (recreate) and
    // a live-but-unpainted surface (nudge). See PAUSE-019.
    final activeIdx = AppLifecycleEngine.activeLoadedIndex(
      currentIndex: _sites.current,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loadedRows,
    );
    if (activeIdx != null) {
      await _host.probeRenderer(
        _sites.models[activeIdx],
        trigger: 'memory-pressure',
      );
      if (!_host.mounted) return;
      _surface.nudge('memory-pressure');
    }
  }

  /// Puts [site] on screen, or the webspace list when null, building its
  /// webview on first use and keeping its cookies apart from the others. A
  /// site removed before the call has nothing left to show, and is not shown.
  ///
  /// The input's own step, before any await: the version, the marker and
  /// the place the flow starts at ([ActivationTable.activationFlow]).
  Future<void> activate(WebViewModel? site) async {
    if (site != null && !_sites.models.contains(site)) return;
    final flow = _flow(target: site);
    if (site == null) {
      // The goHome step commits the screen before any await (NAV-010):
      // every step after it is a native round-trip that can throw, be
      // superseded, or never answer at all, and each of those would
      // otherwise abandon the call with the site the user asked to leave
      // still on screen.
      await _runFlow(flow, from: ActivationPlace.goHome);
      return;
    }
    LogTag.cookieIsolation.debug(
      'Switching to site ${_sites.models.indexOf(site)}: '
      '"${site.name}" (siteId: ${site.siteId})',
      sensitive: true,
    );
    LogTag.cookieIsolation.debug(
      'Target domain: ${getBaseDomain(site.initUrl)}',
      sensitive: true,
    );
    LogTag.cookieIsolation.debug('Currently loaded rows: ${_sites.loadedRows}');
    await _runToExit(flow, from: ActivationPlace.tap);
  }

  /// The list's webspace changed and stopped showing [leaving]
  /// (WEBSPACE-013): an input that supersedes an activation in flight, whose
  /// site goes on loading behind the list, and once the device is online
  /// unloads what it leaves on the shared jar, as choices that spare the
  /// site on screen and the one kept loading (PAUSE-006).
  Future<void> switchWebspace({required Set<WebViewModel> leaving}) =>
      _runFlow(_flow(target: null, leaving: leaving), from: ActivationPlace.space);

  /// The flow from [from] to its end. Every way out runs the exit step, a
  /// throw from a platform call included: the marker goes only with its
  /// own activation, and a screen left on a site with no webview goes home.
  Future<void> _runToExit(
    StepContext<ActivationFlow> flow, {
    required ActivationPlace from,
  }) async {
    var left = from;
    try {
      left = await ActivationTable.activationFlow.run(flow, from: from);
    } finally {
      if (left != ActivationPlace.done) {
        await _runFlow(flow, from: ActivationPlace.exit);
      } else {
        _flows.remove(flow);
      }
    }
  }

  /// The flow from [from] until it leaves the table, done with once it has.
  Future<ActivationPlace> _runFlow(
    StepContext<ActivationFlow> flow, {
    required ActivationPlace from,
  }) async {
    try {
      return await ActivationTable.activationFlow.run(flow, from: from);
    } finally {
      _flows.remove(flow);
    }
  }

  /// A flow for the input that names [target] (none for a return home or
  /// a pressure plan), in flight from now; the input's own step sets the
  /// rest.
  StepContext<ActivationFlow> _flow({
    required WebViewModel? target,
    Reached<Launched>? launch,
    NestedRequest? opening,
    Set<WebViewModel>? leaving,
  }) {
    final flow = StepContext(ActivationFlow(_reach,
        target: target, launch: launch, opening: opening, leaving: leaving));
    _flows.add(flow);
    return flow;
  }

  final SerialQueue _preloads = SerialQueue('preloads');

  /// Builds [siteId]'s webview off screen, as the notification sites are at
  /// launch: an activation that does not show. On the shared jar its
  /// session is restored before its webview exists; under containers its
  /// container is recorded first, after the launch sweep (CONT-004). An
  /// input that lands meanwhile supersedes it as it would an activation, and
  /// it starts while no activation or other preload runs, so it never
  /// supersedes one. A site whose base domain a loaded site holds on the
  /// shared jar is skipped (ISO-001). Preloads run one at a time, and only
  /// in the launch, whose proof [after] is: the model's `ColdStart`.
  Future<PreloadOutcome> preload(
    SiteId siteId, {
    required Reached<Launched> after,
  }) => _preloads.run(() => _preload(siteId, after: after));

  Future<PreloadOutcome> _preload(
    SiteId siteId, {
    required Reached<Launched> after,
  }) async {
    final target = _sites.byId(siteId);
    if (target == null) return PreloadOutcome.skipped;
    final flow = _flow(target: target, launch: after);
    if (!ActivationTable.activationFlow.admits(ActivationPlace.preload, on: flow)) {
      _flows.remove(flow);
      return _sites.activating != null
          ? PreloadOutcome.busy
          : PreloadOutcome.skipped;
    }
    await _runToExit(flow, from: ActivationPlace.preload);
    // Not loaded, as an activation's target is not shown (ISO-014); the
    // next activation empties and refills the jar.
    if (ActivationTable.unrestored.valueOr(none: false).run(flow)) {
      return PreloadOutcome.skipped;
    }
    return flow.world.committed ? PreloadOutcome.loaded : PreloadOutcome.busy;
  }

  /// [site], whose opening a webspace switch superseded, goes on loading
  /// off screen (WEBSPACE-013): a flow of its own, started in the switch's
  /// turn, that takes the preload's steps from its own input.
  void _keepLoading(WebViewModel site) {
    final flow = _flow(target: site);
    unawaited(
      _host.spawned(() => _runToExit(flow, from: ActivationPlace.keep)),
    );
  }

  /// Opens [target]'s nested screen at [opening]'s page (LIR-011): first the
  /// running sites the screen would repoint go, asked again after every
  /// round and once more when the proxy has moved, so one that loaded
  /// meanwhile goes too (PROXY-008, TOR-014). A newer input supersedes it.
  /// One at a time: an open while one runs is dropped.
  Future<void> openNested(
    WebViewModel target, {
    required NestedRequest opening,
  }) async {
    if (!_sites.models.contains(target)) return;
    final flow = _flow(target: target, opening: opening);
    if (!ActivationTable.activationFlow.admits(ActivationPlace.nested, on: flow)) {
      _flows.remove(flow);
      return;
    }
    await _runFlow(flow, from: ActivationPlace.nested);
  }

  /// The webspace list on screen, drawn: the page shows what an activation
  /// decided only once it rebuilds.
  void _leftForHome() {
    _host.exitFullscreen();
    _host.rebuild();
  }

  /// Unloads [site], a site a reset sends home (PAUSE-007): the unload
  /// input, a plan that picks that site alone, so a tap that opens it
  /// meanwhile wins and the unload backs off (BUG-033). Under the legacy
  /// engine the shared jar is captured first (ISO-002): the next activation
  /// empties it after attributing it to the loaded sites only, so a site
  /// unloaded without the capture would lose what it set since its own
  /// activation.
  ///
  /// The site on screen stays loaded, its webview let go of so the frame
  /// builds it afresh: the screen never shows a site that is not loaded
  /// (LAZY-007), and a caller that finds it still on screen activates
  /// nothing.
  Future<void> unload(WebViewModel site, {required UnloadReason reason}) async {
    assert(reason.chosen, 'the unload input picks its site ($reason)');
    if (!_sites.models.contains(site)) return;
    if (identical(site, _sites.shown)) {
      site.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
      return;
    }
    final flow = _flow(target: site);
    flow.world.plan = ResidencyPlan(unloads: [(site: site, reason: reason)]);
    await _runFlow(flow, from: ActivationPlace.unload);
  }

  ResidencyPlan residencyPlan(ResidencyEvent event) =>
      SiteUnloadEngine.plan(_residency, event: event);

  /// False when [isStale] turned true partway; see [SiteUnloadEngine.apply].
  Future<bool> applyResidency(
    ResidencyPlan plan, {
    required bool Function() isStale,
  }) => SiteUnloadEngine.apply(_residency, plan: plan, isStale: isStale);

  /// Capture [model]'s navigation state to encrypted on-disk storage.
  /// Returns true if bytes were captured and the store took them. No-op for
  /// incognito sites or when there's nothing to save.
  ///
  /// Does NOT mutate `model.lifecycleState` — callers that are
  /// disposing the webview should do that themselves (typically
  /// flipping to [SiteLifecycleState.savedForRestore]); callers that
  /// are *only* opportunistically persisting (go-home,
  /// app-background) should leave the state at [SiteLifecycleState.resident]
  /// since the webview is still in memory.
  Future<bool> captureStateBytes(WebViewModel model) async {
    final capture = beginNavCapture(model);
    if (capture == null) return false;
    final bytes = await capture.read();
    if (bytes == null || !capture.stillHolds()) return false;
    return capture.save(bytes);
  }

  /// A capture of [model]'s back stack, keyed by the tab its webview was
  /// built for, which is not always the active one; null when that tab
  /// keeps none: archive-tier (ARCH-006) and incognito sites never persist
  /// nav state, and a hosted tab only when its host would keep it
  /// (LIR-022). The key is read now, before any await: a container flip
  /// (LIR-034) landing while the capture runs would make a key read
  /// afterwards name another identity.
  NavCapture? beginNavCapture(WebViewModel model) {
    final tab = model.tabs
        .where((t) => t.id == model.tabBinding.built)
        .firstOrNull;
    if (tab == null || !model.tabPersistsNavState(tab)) return null;
    return SiteNavCapture(model, tab: tab, navStates: _navStates);
  }

  /// Quiesce the site the user is leaving — a site switch, or a return to the
  /// webspace list (which also captures nav state): [steps] of
  /// [_captureStep] and [_pauseSteps].
  ///
  /// Ordering is CAM-012 / BGAUDIO-009: on iOS the per-instance pause blocks
  /// the page's JS thread, so the camera stop and the media pause have to be
  /// dispatched before it or they sit queued behind it forever. That same
  /// freeze is why the engine bounds the sequence — a page an earlier pause
  /// left frozen never answers `evaluateJavascript` again, and the caller's
  /// own state change must not hang on it (NAV-010).
  Future<void> _teardown(
    WebViewModel model, {
    required int version,
    required List<SiteTeardownStep> steps,
  }) async {
    final result = await SiteTeardownEngine.quiesceOutgoing(
      superseded: () => version != _sites.activationVersion,
      steps: steps,
    );
    if (result.isClean) return;
    LogService.instance.log(
      LogTag.webView,
      message:
          'Teardown of "${model.name}" ran ${result.ran}'
          '${result.failed.isEmpty ? '' : ', failed ${result.failed}'}'
          '${result.stalledOn == null ? '' : ', stalled on ${result.stalledOn}'}'
          '${result.supersededBefore == null ? '' : ', superseded before ${result.supersededBefore}'}',
      level: result.stalledOn == null ? LogLevel.info : LogLevel.warning,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Each answers true: their calls go through the controller wrapper, which
  /// already reads a channel failure as no reply.
  List<SiteTeardownStep> _pauseSteps(WebViewModel model) => [
    SiteTeardownStep('stopRealCapture',
        run: () => model.stopRealCapture().then((_) => true)),
    SiteTeardownStep('pauseMediaPlayback',
        run: () => model.pauseMediaPlayback().then((_) => true)),
    SiteTeardownStep('pauseWebView',
        run: () => model.pauseWebView().then((_) => true)),
  ];

  /// Decrypt the cached/imported HTML for [m] into memory, so the build's
  /// synchronous `getHtmlSync` hits. Uses the same [htmlSourceFor]
  /// classification as the build's `initialHtml` read, so the preload can
  /// never target a different store than the read (a blank site). Waited for
  /// only when the build renders it: a page snapshot is megabytes, and an
  /// online start reads it only if the webview is rebuilt offline later.
  Future<void> ensureSiteHtmlForModel(WebViewModel m) async {
    final source = htmlSourceFor(
      incognito: m.incognito,
      isArchiveTier: m.isArchiveTier,
      initUrl: m.initUrl,
    );
    final loading = switch (source) {
      HtmlSource.import => HtmlImportStorage.instance.preloadOne(m.siteId),
      HtmlSource.cache => HtmlCacheService.instance.preloadOne(m.siteId),
      HtmlSource.none => Future<void>.value(),
    };
    if (rendersStoredHtml(source,
        htmlCachingEnabled: m.htmlCachingEnabled,
        online: ConnectivityService.instance.lastKnownOnline)) {
      await loading;
    } else {
      unawaited(loading);
    }
  }

  /// Whether a nested screen is opening: an open in flight, its screen not
  /// yet up, which a wake's check waits out as it does an activation, since
  /// its pop may bring a site back on another route (BUG-037).
  bool get opensNested => _kindsInFlight.contains(FlowKind.nested);

  /// [ActivationTable.routeFree] for [site] beside what runs now, with no flow in hand: a
  /// wake's check asks it before it claims its place (NOTIF-016).
  bool routeFreeFor(WebViewModel site) => ActivationTable.routeFree
      .call([Expr<WebViewModel, ActivationFlow>(run: (_) => site, tla: 'site', reads: Reads.none)])
      .run(StepContext(ActivationFlow(_reach,
          target: null, launch: null, opening: null, leaving: null)));

  /// What the activation does once its target's webview resumed: the probe,
  /// the sweep, the shell, the surface and the background schedule.
  void _afterResume(WebViewModel target, {required int version}) {
    // A site that sat offscreen while the OS reclaimed memory can come back
    // with a dead renderer (iOS content-process jettison whose termination
    // delegate never fired) or a blank surface (Android hybrid-composition).
    // Probe and recover so a shortcut tap or tab switch doesn't land on a
    // black/blank page. See PAUSE-013.
    unawaited(_host.probeRenderer(target, trigger: 'site-switch'));

    // Defensive sweep: pause every other loaded webview so background
    // sites don't run animations / GPS listeners / non-throttled
    // raf callbacks when the user isn't looking at them. Steady state
    // already has them paused (each becomes paused when it last lost
    // active status above), but a path that adds to _sites.loaded
    // without going through the previous-active pause would leave
    // it unpaused. pauseWebView() is idempotent.
    //
    // unawaited: subsequent activation logic (fullscreen, logging)
    // doesn't depend on these completing, and a page whose JS thread is
    // frozen may never answer at all. Race-wise the version guard inside
    // the teardown is what keeps a sweep still in flight from pausing the
    // site a newer activation has since resumed.
    //
    // (Per-instance pause() doesn't stop JavaScript — see
    // openspec/specs/webview-pause-lifecycle/spec.md. This is a
    // CPU/battery optimization, not RAM. The LRU cap and OS memory
    // pressure handler cover RAM.)
    for (final model in _sites.loaded.toList()) {
      if (identical(model, target)) continue;
      // Camera stop is dispatched before the pause (CAM-012) and covers the
      // sites pauseWebView() exempts — a notification or background-audio
      // site keeps its JS running, which is exactly where a forgotten capture
      // would survive.
      unawaited(_teardown(model, version: version, steps: _pauseSteps(model)));
    }

    if (target.fullscreenMode) {
      _host.enterFullscreen();
    } else {
      _host.exitFullscreen();
    }

    LogTag.cookieIsolation.debug(
      'After switch, loaded rows: ${_sites.loadedRows}',
      sensitive: true,
    );
    // Force the just-activated Android platform-view surface to recomposite.
    // Bringing a webview onstage (tab tap, shortcut open, cold-start restore)
    // can re-attach the hybrid-composition SurfaceView blank: the page is alive
    // (JS runs, DOM serializes) but nothing paints and the native overscroll
    // gesture is dead, so pull-to-refresh can't recover it — only this relayout
    // can. _probeRendererAndRecover above only relayouts web content, not the
    // surface (see its doc), so it does not cover this. No-op off Android.
    //
    // Activating a site whose document is still in flight has the PAUSE-021
    // ordering on top of that: this nudge drains against a surface that has
    // nothing to show yet, and the commit lands afterwards. Latch it so
    // onLoadSettled repaints the committed document (PAUSE-025).
    if (target.isLoading) _surface.armCommitLatch();
    _surface.nudge('activate');
    // _sites.loaded may have changed (LRU eviction, conflict unload,
    // first-load of target), so re-evaluate the background refresh
    // schedule, and the iOS audio session: the first load of a
    // background-audio site must activate `.playback` before the user starts
    // playback in it. No-op on non-iOS / non-Android.
    _host.backgroundSitesChanged();
  }
}
