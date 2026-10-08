import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/diag_seed.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// What the app-lifecycle flows ask of the page.
abstract interface class LifecycleHost implements PageHost {
  /// Saves [model]'s back stack; false when there was nothing to save.
  Future<bool> captureNavState(WebViewModel model);

  /// Full screen's system UI mode again, which a resume can lose.
  void reapplyFullscreen();

  /// A share intent that arrived while the app was away.
  Future<void> handleShareIntent();
}

/// The app leaving and returning to the foreground: what pauses, what is
/// captured, and the resume sequence that repaints and recovers the site on
/// screen (PAUSE-*).
class AppLifecycleController {
  AppLifecycleController(
    this._sites, {
    required LifecycleHost host,
    required this.surface,
    required this.shortcuts,
    required this.background,
    required this.cookies,
  }) : _host = host;

  final SiteRuntime _sites;
  final LifecycleHost _host;
  final SurfaceRepaintController surface;
  final ShortcutController shortcuts;
  final BackgroundSitesController background;
  final CookieManager cookies;

  /// The JS pause in flight, which a resume drains first: a quick
  /// inactive→resumed could otherwise land the resume before the pause and
  /// leave the webview stuck.
  Future<void>? _pauseFuture;
  final _resumeGuard = ReentryGuard();

  /// Re-entry guard for [_retryIncompleteLoad]: `resumed` can fire again
  /// while a retry awaits its backoff, and two loops would fight over one
  /// webview's navigation.
  final _retryGuard = ReentryGuard();

  /// When the app last went to `paused`, for the background log's resume line.
  DateTime? _backgroundedAt;

  void changed(AppLifecycleState state) {
    // Persist the protection-report counters on every step away from the
    // foreground, not only on `paused` (STATS-002): desktop never delivers
    // `paused` at all, and a foreground kill delivers nothing, so whatever
    // sits inside the debounce window is what a restart loses. The write is
    // gated on a dirty flag, so a transient `inactive` — a native <select>,
    // a permission prompt — with nothing new recorded costs nothing.
    if (state != AppLifecycleState.resumed) {
      unawaited(BlockStatsService.instance.flush());
    }
    // Only `paused` is a real backgrounding. `inactive` fires for any
    // transient focus loss (a native <select>, the app-switcher peek, a
    // permission prompt, an incoming call on iOS), where pausing the WebView
    // would dismiss the popup or the JS the user is interacting with (#308).
    if (state == AppLifecycleState.paused) {
      _backgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _foregrounded();
    }
  }

  void _backgrounded() {
    // URL-ephemeral sites (alwaysOpenHome / incognito) revert to their initUrl
    // only on a genuine restart (AOH-002) and on a shortcut tap (AOH-004),
    // never on a transient background: leaving to fetch an emailed 2FA code
    // must return to the page in progress (#333). The plan has no reset.
    final pausePlan = AppLifecycleEngine.backgroundPlan(
      currentIndex: _sites.current,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
      notificationsEnabled: (i) => _sites.models[i].effectiveNotificationsEnabled,
      backgroundAudioEnabled: (i) =>
          _sites.models[i].effectiveBackgroundAudioEnabled,
      cookieFlushSupported: CookieManager.flushSupported,
    );
    // Non-sensitive decision line: whether the background froze JS or a
    // notification/background-audio exemption kept it running, with the
    // inputs to that decision (BGAUDIO-002, NOTIF-011), or a jsPause=true
    // line reads as a bug when no loaded site has the toggle on.
    int loadedWith(bool Function(WebViewModel m) flag) => _sites.loaded
        .where(
            (i) => i >= 0 && i < _sites.models.length && flag(_sites.models[i]))
        .length;
    final loadedBgAudio = loadedWith((m) => m.effectiveBackgroundAudioEnabled);
    final loadedNotif = loadedWith((m) => m.effectiveNotificationsEnabled);
    _backgroundedAt = DateTime.now();
    BackgroundLog.instance.record(
      LogTag.lifecycle,
      message: 'App background: jsPause=${pausePlan.jsPauseIndex != null} '
          'capture=${pausePlan.captureStateIndex != null} '
          'bgAudio=$loadedBgAudio notif=$loadedNotif loaded',
    );
    // BGAUDIO-012: a player that stops when its page reports hidden (YouTube
    // and every other built for a tab) is told first.
    _setBackgroundPlayback(background: true);
    // BGAUDIO-009: a site never opted in must not keep sounding through a
    // backgrounded app (and keep the system controls up). Dispatched ahead of
    // the rest: the JS pause blocks the page's JS thread on iOS, and Android's
    // CookieManager.flush() blocks the platform thread on disk I/O with every
    // later channel message queued behind it.
    final mediaStops = <int, Future<void>>{};
    for (final i in pausePlan.mediaPauseIndices) {
      if (i < 0 || i >= _sites.models.length) continue;
      mediaStops[i] = _sites.models[i].pauseMediaPlayback();
    }
    final allMediaStopped = Future.wait(mediaStops.values);
    // The last moment before the OS may kill the process, and Chromium commits
    // cookies lazily. Best-effort: nothing downstream waits on it.
    if (pausePlan.flushCookies) unawaited(cookies.flush());
    if (pausePlan.jsPauseIndex case final idx?) {
      final stopped = mediaStops.remove(idx) ?? Future<void>.value();
      _pauseFuture =
          stopped.then((_) => _sites.models[idx].pauseForAppLifecycle());
    }
    for (final stop in mediaStops.values) {
      unawaited(stop);
    }
    if (pausePlan.captureStateIndex case final idx?) {
      final model = _sites.models[idx];
      unawaited(_host.captureNavState(model));
      // A background process can lose the network under a navigation and
      // come back to an error page, or to one that never arrives (PAUSE-022).
      model.resumeReload.noteAppBackgrounded();
    }
    background.noteBackgrounded();
    unawaited(background.reschedule());
    // After the media stops: WebKit republishes its Now Playing entry when it
    // processes a pause, so clearing before that leaves the controls up
    // (BGAUDIO-009).
    unawaited(allMediaStopped.then((_) => background.updateAudioSession()));
  }

  void _foregrounded() {
    final since = _backgroundedAt;
    if (since != null) {
      _backgroundedAt = null;
      final c = background.counts();
      BackgroundLog.instance.record(
        LogTag.lifecycle,
        message:
            'App resumed after ${DateTime.now().difference(since).inSeconds}s '
            'in background: notif sites ${c.enabled} enabled, '
            '${c.loaded} loaded',
      );
    }
    // BGAUDIO-012: a player that pauses when hidden behaves as it always has.
    _setBackgroundPlayback(background: false);
    // Before the async resume sequence, so a late SurfaceView re-attach (a
    // metrics change) is caught after its one tail nudge (PAUSE-020).
    surface.openResumeWindow();
    unawaited(_onResumed());
    background.noteResumed();
  }

  void _setBackgroundPlayback({required bool background}) {
    for (final i in _sites.loaded) {
      if (i < 0 || i >= _sites.models.length) continue;
      if (!_sites.models[i].effectiveBackgroundAudioEnabled) continue;
      unawaited(_sites.models[i].setBackgroundPlayback(active: background));
    }
  }

  /// The resume sequence, in a fixed order. The lifecycle resume (draining
  /// the JS pause, resuming timers and the active site) completes before a
  /// shortcut is handled, since both move the site on screen and pause or
  /// resume webviews; and one repaint then runs against the final site
  /// rather than two loops interleaving.
  Future<void> _onResumed() async {
    await _resumeGuard.run(() async {
      await _resumeAfterPause();
      if (!_host.mounted) return;
      await shortcuts.handleWarmLaunch();
      if (!_host.mounted) return;
      await _host.handleShareIntent();
      if (!_host.mounted) return;
      // Pins can come and go from the launcher while the app is away.
      unawaited(shortcuts.refreshPinned());
      // The activity may have been recreated with a blank surface (PAUSE-015).
      surface.nudge('resume');
      unawaited(_diagReload());
      // A repaint cannot recover a page that never loaded: re-issue a load the
      // OS stranded while away (PAUSE-022). Bounded retries with a backoff,
      // so not awaited inside the sequence.
      final retryIdx = AppLifecycleEngine.activeLoadedIndex(
        currentIndex: _sites.current,
        siteCount: _sites.models.length,
        loadedIndices: _sites.loaded,
      );
      if (retryIdx != null) {
        unawaited(_retryIncompleteLoad(_sites.models[retryIdx]));
      }
    });
  }

  Future<void> _resumeAfterPause() async {
    if (_pauseFuture case final pausing?) {
      await pausing;
      _pauseFuture = null;
    }
    final resumeIdx = AppLifecycleEngine.resumeJsIndex(
      currentIndex: _sites.current,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
      notificationsEnabled: (i) => _sites.models[i].effectiveNotificationsEnabled,
      backgroundAudioEnabled: (i) =>
          _sites.models[i].effectiveBackgroundAudioEnabled,
    );
    if (resumeIdx != null) {
      await _sites.models[resumeIdx].resumeFromAppLifecycle();
    }
    final probeIdx = AppLifecycleEngine.activeLoadedIndex(
      currentIndex: _sites.current,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
    );
    if (probeIdx != null) {
      unawaited(probeRenderer(_sites.models[probeIdx], trigger: 'resume'));
    }
    _host.reapplyFullscreen();
  }

  /// Recreates [model]'s webview when its renderer is gone (PAUSE-013,
  /// BUG-002); a live one is left to the surface nudge. No-op without a
  /// controller: a first load whose controller is not created yet.
  Future<void> probeRenderer(WebViewModel model, {required String trigger}) async {
    final controller = model.controller;
    if (controller == null) return;
    final gone = await surface.rendererGone(controller,
        trigger: trigger, siteId: model.siteId);
    // A concurrent recreate may have swapped the controller already.
    if (!gone || !identical(model.controller, controller)) return;
    LogTag.webView.warning(
        'Renderer probe failed for "${model.name}" (siteId: ${model.siteId}) — recreating',
        sensitive: true);
    model.handleRendererGone(didCrash: false);
  }

  /// [ResumeReloadEngine]'s recovery for the site on screen (PAUSE-022): the
  /// engine decides whether and what to re-issue; this owns the clock, the
  /// connectivity gate and the call. Bails at every await if the site is no
  /// longer the one on screen.
  Future<void> _retryIncompleteLoad(WebViewModel model) async {
    await _retryGuard.run(() async {
      for (var i = 0; i < ResumeReloadEngine.maxAttempts; i++) {
        var plan = model.resumeReload.planRetry();
        if (plan.action == ResumeRetryAction.waitAndReplan) {
          await Future.delayed(plan.delay);
          if (!_stillShown(model)) return;
          model.resumeReload.noteStallGraceElapsed();
          plan = model.resumeReload.planRetry();
        }
        if (plan.action != ResumeRetryAction.retryNow) return;
        // Offline is an honest error page; re-issuing just reprints it.
        if (!await ConnectivityService.instance.isOnline()) return;
        if (!_stillShown(model)) return;
        model.resumeReload.noteRetryIssued();
        LogTag.resumeReload.debug(
            'attempt=${model.resumeReload.attempts} -> reissuing stranded load');
        await model.reissueLoadAndRepaint(plan.url!);
        await Future.delayed(ResumeReloadEngine.retryBackoff);
        if (!_stillShown(model)) return;
      }
    });
  }

  bool _stillShown(WebViewModel model) =>
      _host.mounted &&
      model.controller != null &&
      identical(_sites.shown, model);

  /// Adb white-screen tier only (INTEG-011): the launch intent's reloads,
  /// through the production refresh funnel. A reload carries no window
  /// visibility change, so nothing below Dart repaints the surface it blanks,
  /// and no scenario could reach it from the overflow menu. Delayed so the
  /// resume nudge before it has drained; otherwise the scenario measures the
  /// resume instead of the reload.
  Future<void> _diagReload() async {
    final count = await DiagSeed.takeReloadRequest();
    if (count == null || count <= 0 || !_host.mounted) return;
    await Future.delayed(const Duration(seconds: 1));
    for (var i = 0; i < count; i++) {
      if (!_host.mounted) return;
      final shown = _sites.shown;
      if (shown == null) return;
      unawaited(shown.reloadAndRepaint());
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  /// The system text scale changed: every built webview follows it.
  void textScaleChanged() {
    final zoom = WebViewFactory.systemTextZoomPercent();
    for (final i in _sites.loaded) {
      if (i < _sites.models.length) _sites.models[i].controller?.setTextZoom(zoom);
    }
  }
}
