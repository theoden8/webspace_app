import 'dart:async';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:webspace/controllers/desktop_tray.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/wake_candidates.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/background_task_service.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/services/foreground_poll_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/refresh_schedule_engine.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/wake_baseline_store.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_headless.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/headless_site_check.dart';

/// What the background-site flows ask of the page.
abstract interface class BackgroundSitesHost implements PageHost {
  Future<void> activate(WebViewModel site);

  /// A notification tap is an app entry point: the site it opens comes up
  /// with nothing over the page, neither a pushed route nor a revealed tab
  /// strip.
  void resetForEntry();

  /// Points Tor's exit country at what the sites at [indices] agree on
  /// (TOR-014).
  void syncTorExitPin(Iterable<WebViewModel> sites);

  /// What the page answers for every site webview; a headless check takes
  /// them unattended.
  WebViewHostHooks get webViewHooks;

  /// Whether a check of [site], which runs as [site] itself, may run beside
  /// what runs now: the activation's `RouteFree` (PROXY-008, TOR-014).
  bool routeFree(WebViewModel site);

  /// Whether a nested open is in flight, which a wake's check waits out.
  bool get nestedOpening;
}

/// Sites that work while another is on screen or the app is away:
/// notification sites (NOTIF-*) and background-audio sites (BGAUDIO-*). Owns
/// the OS refresh schedule, the audio session, the foreground poll and the
/// background wake.
class BackgroundSitesController {
  BackgroundSitesController(this._sites, {required BackgroundSitesHost host})
      : _host = host;

  final SiteRuntime _sites;
  final BackgroundSitesHost _host;
  final BackgroundWakeEngine<WebViewModel> _wakeEngine = BackgroundWakeEngine();
  Timer? _foregroundPollTimer;

  /// The wake's side of the app: its checks, the route they run on, and
  /// the app's lifecycle as the wake's table hears it (NOTIF-016).
  late final _WakeHost _wakeHost = _WakeHost(_sites, host: _host);

  /// The desktop's status icon, whose sites open as a notification's do.
  late final DesktopTray _tray = DesktopTray(_sites, open: _openFromOutside);

  /// What the background log reports instead of names: sites with
  /// notifications on, how many of them are loaded, and how many have a live
  /// webview a wake can reload.
  ({int enabled, int loaded, int live}) counts() {
    var enabled = 0;
    var loaded = 0;
    var live = 0;
    for (final m in _sites.models) {
      if (!m.effectiveNotificationsEnabled) continue;
      enabled++;
      if (!_sites.loaded.contains(m)) continue;
      loaded++;
      if (m.controller != null) live++;
    }
    return (enabled: enabled, loaded: loaded, live: live);
  }

  bool get anyNotificationSites =>
      _sites.models.any((m) => m.effectiveNotificationsEnabled);

  /// NOTIF-005-A: Android's `ProxyController` is process-wide, so a site can
  /// become a notification site only if every other one shares its proxy.
  /// The first conflicting site's name, or null when [target] is free to.
  /// Null off Android, where `BGAppRefreshTask` shares no proxy.
  String? notificationsBlockedBy(WebViewModel target) {
    if (!hostIsAndroid) return null;
    final others = [
      for (final m in _sites.models)
        if (!identical(m, target) && m.effectiveNotificationsEnabled) m,
    ];
    // Outbound settings, so two Tor sites differ by their isolation tags.
    final blocker = ProxyConflictEngine.firstConflict(
      targetProxy: target.outboundProxySettings,
      others: others,
      proxyOf: (m) => m.outboundProxySettings,
      routesPerSite: ProxyRouterService.instance.routesPerSite,
    );
    if (blocker == null) return null;
    return blocker.name.isNotEmpty
        ? blocker.name
        : (blocker.initUrl.isNotEmpty ? blocker.initUrl : 'Another site');
  }

  /// What the last [reschedule] asked the OS for; null before the first.
  bool? _scheduled;

  /// NOTIF-005-{I,A}: a refresh is scheduled iff a site has notifications
  /// on, loaded or not: a wake checks the unloaded ones headless (NOTIF-016).
  /// iOS `BGAppRefreshTask`, Android a `WorkManager` periodic request. The
  /// request is touched only when that answer changes or the app is leaving
  /// the screen ([RefreshScheduleEngine]).
  Future<void> reschedule({bool leavingScreen = false}) async {
    if (!hostIsIOS && !hostIsAndroid) return;
    final c = counts();
    final any = c.enabled > 0;
    final action = RefreshScheduleEngine.next(
      scheduled: _scheduled,
      anyEnabled: any,
      leavingScreen: leavingScreen,
    );
    if (action == RefreshScheduleAction.keep) return;
    if (_scheduled != any) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        message: '${any ? "schedule" : "cancel"} refresh — '
            'notif sites: ${c.enabled} enabled, ${c.loaded} loaded',
      );
    }
    _scheduled = any;
    if (action == RefreshScheduleAction.schedule) {
      await BackgroundTaskService.instance.scheduleNextRefresh();
    } else {
      await BackgroundTaskService.instance.cancelScheduledRefreshes();
    }
  }

  /// BGAUDIO-003: the iOS `.playback` session follows whether a loaded site
  /// has background audio on; active playback under it (with the `audio`
  /// background mode) keeps iOS from suspending the app. Idempotent.
  Future<void> updateAudioSession() async {
    final any = _sites.loaded.any((m) => m.effectiveBackgroundAudioEnabled);
    await BackgroundTaskService.instance.setBackgroundAudioActive(active: any);
    // With nothing to drive it, the media surface goes; on iOS that also
    // removes the Now Playing entry WebKit publishes for any page that plays,
    // which would outlive the audio as a control reaching nothing
    // (BGAUDIO-009/010). While a site is loaded its page reports raise it.
    if (!any) await MediaSessionService.instance.clearOsMediaSurface();
  }

  /// A notification site leaving the loaded set is checked headless by the
  /// next wake rather than reloaded (NOTIF-016, DEVTOOLS-012). Call after the
  /// removal.
  void noteUnloaded(WebViewModel m, {required String reason}) {
    if (!m.effectiveNotificationsEnabled) return;
    final c = counts();
    BackgroundLog.instance.record(
      LogTag.siteUnload,
      message: 'notification site unloaded ($reason); '
          '${c.loaded} of ${c.enabled} still loaded, '
          'the rest are checked headless',
      sensitive: 'unloaded notification site "${m.name}" '
          '(siteId ${m.siteId}): $reason',
    );
  }

  /// Reloads the notification sites other than the one on screen so their
  /// page JS can fire what it has pending (NOTIF-006): the 5-minute
  /// foreground tick, and a WorkManager tick landing while foregrounded.
  Future<void> refreshSites() async {
    final plan = ForegroundPollEngine.plan(
      siteCount: _sites.models.length,
      currentIndex: _sites.current,
      loadedIndices: _sites.loadedRows,
      isPolled: (i) => _sites.models[i].effectiveNotificationsEnabled,
    );
    final reload = [for (final i in plan.reload) _sites.models[i]];
    final unloaded = plan.unloaded;
    var reloaded = 0;
    for (final m in reload) {
      if (m.controller == null) continue;
      await m.reloadAndRepaint();
      reloaded++;
    }
    BackgroundLog.instance.record(
      LogTag.backgroundTask,
      message: 'refresh notif sites: reloaded=$reloaded, '
          'skipped(unloaded)=$unloaded, '
          'skipped(no controller)=${reload.length - reloaded}',
    );
  }

  /// NOTIF-013/014/016: what an OS background wake runs. Returns once the
  /// checked pages have settled, which is what ends the OS task.
  Future<void> wake() async {
    final c = counts();
    BackgroundLog.instance.record(
      LogTag.backgroundTask,
      message: 'background wake: notif sites ${c.enabled} enabled, '
          '${c.loaded} loaded, ${c.live} with a live webview',
    );
    // A wake resumes the process without the app coming back to the
    // foreground, so the resume check tor's listener needs has not run yet
    // (TOR-024), and a Tor notification site would reload through a dead one.
    await TorService.instance.revive();
    // The OS wakes the app only off screen; a process it started for the
    // wake has heard no lifecycle event to say so.
    if (_sites.fore) _wakeEngine.background(_wakeHost);
    final report = await _wakeEngine.wake(_wakeHost);
    for (var i = 0; i < report.sites.length; i++) {
      final o = report.sites[i];
      final line =
          describeWakeSite(o, position: i + 1, count: report.sites.length);
      BackgroundLog.instance.record(LogTag.backgroundTask, message: line.normal,
          level: o.skip == null ? LogLevel.info : LogLevel.warning,
          sensitive: line.sensitive);
    }
    BackgroundLog.instance.record(
      LogTag.backgroundTask,
      message: 'background wake done: ${report.count(WakeMode.live)} live, '
          '${report.count(WakeMode.headless)} headless, '
          '${report.skipped} skipped, unread fallback posts=${report.posted}, '
          'took ${(report.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    await _persistBaselines();
  }

  /// NOTIF-014: the baselines the next process compares against. Incognito
  /// sites keep theirs in memory only.
  Future<void> _persistBaselines() async {
    if (isDemoMode) return;
    await WakeBaselineStore.write(_wakeEngine.baselinesOf({
      for (final m in _sites.models)
        if (m.effectiveNotificationsEnabled && !m.effectiveIncognito) m.siteId,
    }));
  }

  /// The app is leaving the foreground: an iOS grace window for notification
  /// webviews to flush their timers, and each loaded notification site's
  /// unread count as the user can still see it, so a later wake posts only
  /// for what arrived after (NOTIF-014).
  void noteBackgrounded() {
    if (_sites.fore) _wakeEngine.background(_wakeHost);
    _stopForegroundPoll();
    if (!anyNotificationSites) return;
    unawaited(BackgroundTaskService.instance.beginGracePeriod());
    _wakeEngine.forget({for (final m in _sites.models) m.siteId});
    final reads = <Future<void>>[];
    for (final m in _sites.loaded) {
      final c = m.controller;
      if (!m.effectiveNotificationsEnabled || c == null) continue;
      // A refused read is already null: the controller owns that failure.
      reads.add(c
          .getTitle()
          .then((t) => _wakeEngine.noteBaseline(m.siteId, title: t)));
    }
    unawaited(Future.wait(reads).then((_) => _persistBaselines()));
  }

  /// Back in the foreground: the grace window ends and the poll resumes.
  void noteResumed() {
    // A wake's headless checks end here: on Android the site the user opens
    // next moves the one process-wide proxy, and a check still loading would
    // follow it (NOTIF-016).
    if (!_sites.fore) _wakeEngine.foreground(_wakeHost);
    startForegroundPoll();
    unawaited(BackgroundTaskService.instance.endGracePeriod());
  }

  /// A post from the background told the user what the site's title now
  /// counts, so the next wake measures from there (NOTIF-014). Read a beat
  /// later: the page may update its title after posting.
  void _noteBaselineAfterPost(SiteId siteId) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    Future<void>.delayed(const Duration(seconds: 1), () async {
      // A post from a headless check (NOTIF-016) has no controller here; the
      // wake reads that page's title itself before closing it.
      final c = _sites.byId(siteId)?.controller;
      if (c == null) return;
      _wakeEngine.noteBaseline(siteId, title: await c.getTitle());
      unawaited(_persistBaselines());
    });
  }

  /// A tap on a site's notification, or a press on it in the tray
  /// (NOTIF-019).
  void _openFromOutside(SiteId siteId) {
    // A window a close hid is where the site shows (NOTIF-018).
    unawaited(DesktopWindow.instance.show());
    final site = _siteTapped(siteId);
    if (site == null) return;
    _host.resetForEntry();
    unawaited(_host.activate(site));
    _host.rebuild();
  }

  WebViewModel? _siteTapped(SiteId siteId) {
    final site = _sites.byId(siteId);
    if (site == null) {
      LogTag.notification.warning(
          'Tap for unknown siteId: $siteId', sensitive: true);
      return null;
    }
    LogTag.notification.debug(
        'Tap routing to site "${site.name}"', sensitive: true);
    return site;
  }

  /// Taps on posted notifications open their site from here on. Returns the
  /// site whose notification started this process, for the cold start to open
  /// in place of the webspace list; the tap that launched the app reaches no
  /// callback.
  Future<WebViewModel?> wireTaps() async {
    NotificationService.instance.onNotificationTapped = _openFromOutside;
    final siteId = await NotificationService.instance.launchSiteId();
    return siteId == null ? null : _siteTapped(siteId);
  }

  void startForegroundPoll() {
    _foregroundPollTimer?.cancel();
    _foregroundPollTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(refreshSites()),
    );
  }

  void _stopForegroundPoll() {
    _foregroundPollTimer?.cancel();
    _foregroundPollTimer = null;
  }

  /// Startup wiring, once the sites are up: notification posts,
  /// the native refresh handler, the background log's app state and the
  /// Android media transport (BGAUDIO-006).
  Future<void> install() async {
    await NotificationService.instance.init();
    NotificationService.instance.onPosted = _noteBaselineAfterPost;
    // Before the handler below: a wake in a process the OS launched for it
    // compares against what the last process saw (NOTIF-014).
    _wakeEngine.restoreBaselines(await WakeBaselineStore.read());
    // Android's WorkManager tick fires whenever the Flutter engine is
    // reachable, the foreground included, so the site the user is looking at
    // is never reloaded then; a true background wake checks every one. iOS
    // runs a refresh task only in the background, and a process it launched
    // for one has seen no lifecycle event to say so.
    BackgroundTaskService.instance.onBackgroundRefresh = () => !hostIsIOS &&
            AppLifecycleEngine.refreshTickOnScreen(
                WidgetsBinding.instance.lifecycleState)
        ? refreshSites()
        : wake();
    BackgroundTaskService.instance.initialize();
    BackgroundLog.instance.appState = () async {
      final c = counts();
      final lifecycle = WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
      // The OS's answer, not this process's last one: a process that has
      // posted nothing yet has none.
      final permission = await NotificationService.instance.osPermission();
      return [
        MapEntry('app.lifecycle', lifecycle),
        MapEntry('app.notificationSitesEnabled', '${c.enabled}'),
        MapEntry('app.notificationSitesLoaded', '${c.loaded}'),
        MapEntry('app.notificationSitesWithWebview', '${c.live}'),
        MapEntry('app.notificationPermission', switch (permission) {
          true => 'granted',
          false => 'not granted',
          null when hostIsAndroid || hostIsIOS || hostIsMacOS => 'unreadable',
          null => 'not applicable',
        }),
        MapEntry('app.isolation', _sites.useContainers ? 'containers' : 'legacy'),
      ];
    };
    MediaSessionService.instance.initialize();
    unawaited(reschedule());
    _tray.start();
  }

  /// The window went away, which is when the tray gets looked at.
  void windowHidden() => unawaited(_tray.refresh());

  void dispose() {
    _stopForegroundPoll();
    _tray.dispose();
  }
}

class _WakeHost implements BackgroundWakeHost<WebViewModel> {
  _WakeHost(this._sites, {required BackgroundSitesHost host}) : _host = host;

  final SiteRuntime _sites;
  final BackgroundSitesHost _host;

  /// The headless webviews the wake opened (NOTIF-016), by site; the sites
  /// themselves are the runtime's `headless`, which the table writes.
  final Map<SiteId, HeadlessSiteCheck> _headless = {};

  @override
  RuntimeVars<WebViewModel> get vars => _sites.vars;

  @override
  WebViewModel siteOf(SiteId siteId) => _sites.byId(siteId)!;

  @override
  bool routeFree(WebViewModel site) => _host.routeFree(site);

  @override
  bool get nestedOpening => _host.nestedOpening;

  /// Android outside router mode: one proxy override for the process.
  static bool get _proxyIsGlobal =>
      hostIsAndroid && !ProxyRouterService.instance.routesPerSite;

  @override
  List<WakeCandidate> wakeCandidates() {
    final env = WakeEnvironment(
      containers: _sites.useContainers,
      torUp: TorService.instance.status.isUp,
    );
    final models = _sites.models;
    return [
      for (var i = 0; i < models.length; i++)
        wakeCandidateFor(
          models[i],
          loaded: _sites.loaded.contains(models[i]),
          hasWebview: models[i].controller != null,
          proxyBindable: !WebViewFactory.storeBinding(models[i].sitePosture(
                  globalUserScripts: _host.webViewHooks.globalUserScripts(),
                  isolation: _sites.isolation))
              .proxyUnavailable,
          env: env,
        ),
    ];
  }

  // Funnelled like refreshSites: a wake can land on the visible site, and a
  // raw reload blanks it (PAUSE-021).
  @override
  Future<void> reload(SiteId siteId) async =>
      _sites.byId(siteId)?.reloadAndRepaint();

  @override
  Future<bool> applyRoute(SiteId siteId) async {
    final m = _sites.byId(siteId);
    if (m == null) return false;
    try {
      if (_proxyIsGlobal) {
        await ProxyManager().setProxySettings(
          m.proxySettings,
          siteId: m.siteId,
          occupant: (use: RouteUse.headless, site: m.siteId),
        );
      }
      if (TorService.instance.isAvailable &&
          SiteUnloadEngine.torExitConstraint(m) != null) {
        // Tor holds its `up` status while a new pin is applied, so up again
        // means this site's exit country is in force (TOR-014).
        _host.syncTorExitPin([m]);
        if (!await _torUpWithin(_torPinDeadline)) return false;
      }
      return true;
    } on ProxyRefused catch (e) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        message:
            'could not apply the route for a headless check: ${e.runtimeType}',
        level: LogLevel.warning,
        sensitive: 'route for "${m.name}" failed: $e',
      );
      return false;
    }
  }

  static const Duration _torPinDeadline = Duration(seconds: 10);

  static Future<bool> _torUpWithin(Duration deadline) async {
    if (TorService.instance.status.isUp) return true;
    try {
      await TorService.instance.statusStream
          .firstWhere((s) => s.isUp)
          .timeout(deadline);
      return true;
    } on TimeoutException {
      return false;
    } on StateError {
      return false;
    }
  }

  // Android needs nothing: the next webview built applies its own proxy
  // before it loads (WebViewModel.setController). Tor's exit country is put
  // back to what the loaded sites agree on (TOR-014).
  @override
  void releaseRoute() {
    ProcessRoute.instance.releaseEvery(RouteUse.headless);
    if (TorService.instance.isAvailable) {
      _host.syncTorExitPin(_sites.loaded);
    }
  }

  @override
  Future<WakeSkip?> openHeadless(SiteId siteId) async {
    final ended = Completer<void>();
    _opening.add(ended.future);
    try {
      return await _openHeadless(siteId);
    } finally {
      _opening.remove(ended.future);
      ended.complete();
    }
  }

  /// The opens under way, which the app's return waits out before the rule
  /// may move: each disposes its check once it sees the app back.
  final Set<Future<void>> _opening = {};

  Future<WakeSkip?> _openHeadless(SiteId siteId) async {
    final m = _sites.byId(siteId);
    if (m == null) return WakeSkip.headlessFailed;
    if (_sites.fore) return WakeSkip.appInForeground;
    final (check, skip) = await HeadlessSiteChecks.openHeadlessCheck(
        m.headlessCheckConfig(_host.webViewHooks));
    if (check == null) return skip;
    if (_sites.fore) {
      await check.dispose();
      return WakeSkip.appInForeground;
    }
    // On the rule since its route was applied (applyRoute's claim).
    _headless[siteId] = check;
    return null;
  }

  // A check leaves the rule once it is disposed, in the rule's turn: a
  // webview the user opens meanwhile waits to move the rule until no check
  // still loads on the old route (NOTIF-016).
  @override
  Future<void> closeHeadless(SiteId siteId) {
    final check = _headless.remove(siteId);
    return ProcessRoute.instance.vacate(
      [(use: RouteUse.headless, site: siteId)],
      close: () async => check?.dispose(),
    );
  }

  @override
  void closeAllHeadless() => unawaited(_closeAll());

  Future<void> _closeAll() {
    final open = {..._headless};
    _headless.clear();
    return ProcessRoute.instance.vacateEvery(
      RouteUse.headless,
      close: () async {
        await Future.wait([..._opening]);
        for (final c in open.values) {
          await c.dispose();
        }
      },
    );
  }

  @override
  void leave(SiteId siteId) =>
      ProcessRoute.instance.release((use: RouteUse.headless, site: siteId));

  @override
  bool? isLoading(SiteId siteId) {
    final headless = _headless[siteId];
    if (headless != null) return headless.isLoading;
    final m = _sites.byId(siteId);
    return m == null || m.controller == null ? null : m.isLoading;
  }

  @override
  Future<String?> title(SiteId siteId) async {
    final headless = _headless[siteId];
    if (headless != null) {
      try {
        return await headless.title();
      } on PlatformException {
        return null;
      }
    }
    return _sites.byId(siteId)?.controller?.getTitle();
  }

  @override
  bool postedSince(SiteId siteId, {required DateTime since}) {
    final at = NotificationService.instance.lastPostedAt(siteId);
    return at != null && !at.isBefore(since);
  }

  @override
  Future<void> post({
    required SiteId siteId,
    required String siteName,
    required String body,
  }) =>
      NotificationService.instance.show(
        siteId: siteId,
        title: siteName,
        body: body,
        // One fallback per site at a time: a later rise replaces it.
        tag: 'webspace-unread',
        origin: NotificationOrigin.unreadFallback,
      );

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> delay(Duration d) => Future<void>.delayed(d);
}
