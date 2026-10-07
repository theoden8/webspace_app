import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/wake_candidates.dart';
import 'package:webspace/demo_data.dart' show isDemoMode;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/background_task_service.dart';
import 'package:webspace/services/background_wake_engine.dart';
import 'package:webspace/services/foreground_poll_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/wake_baseline_store.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

/// What the background-site flows ask of the page.
abstract interface class BackgroundSitesHost implements PageHost {
  Future<void> activate(int index);

  /// Points Tor's exit country at what the sites at [indices] agree on
  /// (TOR-014).
  void syncTorExitPin(Set<int> indices);

  /// The app-wide user scripts a site may opt into.
  List<UserScriptConfig> get globalUserScripts;
}

/// Sites that work while another is on screen or the app is away:
/// notification sites (NOTIF-*) and background-audio sites (BGAUDIO-*). Owns
/// the OS refresh schedule, the audio session, the foreground poll and the
/// background wake.
class BackgroundSitesController {
  BackgroundSitesController(this._sites, this._host);

  final SiteRuntime _sites;
  final BackgroundSitesHost _host;
  final BackgroundWakeEngine _wakeEngine = BackgroundWakeEngine();
  Timer? _foregroundPollTimer;

  /// The wake in progress, so a return to the foreground can close its
  /// headless checks (NOTIF-016).
  _WakeHost? _activeWake;

  /// What the background log reports instead of names: sites with
  /// notifications on, how many of them are loaded, and how many have a live
  /// webview a wake can reload.
  ({int enabled, int loaded, int live}) counts() {
    var enabled = 0;
    var loaded = 0;
    var live = 0;
    for (var i = 0; i < _sites.models.length; i++) {
      final m = _sites.models[i];
      if (!m.effectiveNotificationsEnabled) continue;
      enabled++;
      if (!_sites.loaded.contains(i)) continue;
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
      routerActive: ProxyRouterService.instance.isActive,
    );
    if (blocker == null) return null;
    return blocker.name.isNotEmpty
        ? blocker.name
        : (blocker.initUrl.isNotEmpty ? blocker.initUrl : 'Another site');
  }

  /// NOTIF-005-{I,A}: a refresh is scheduled iff a site has notifications
  /// on, loaded or not: a wake checks the unloaded ones headless (NOTIF-016).
  /// iOS `BGAppRefreshTask`, Android a `WorkManager` periodic request. Both
  /// submissions replace any pending one, so this is idempotent.
  Future<void> reschedule() async {
    if (!hostIsIOS && !hostIsAndroid) return;
    final c = counts();
    final any = c.enabled > 0;
    BackgroundLog.instance.record(
      'BackgroundTask',
      '${any ? "schedule" : "cancel"} refresh — '
          'notif sites: ${c.enabled} enabled, ${c.loaded} loaded',
    );
    if (any) {
      await BackgroundTaskService.instance.scheduleNextRefresh();
    } else {
      await BackgroundTaskService.instance.cancelScheduledRefreshes();
    }
  }

  /// BGAUDIO-003: the iOS `.playback` session follows whether a loaded site
  /// has background audio on; active playback under it (with the `audio`
  /// background mode) keeps iOS from suspending the app. Idempotent.
  Future<void> updateAudioSession() async {
    var any = false;
    for (var i = 0; i < _sites.models.length; i++) {
      if (!_sites.models[i].effectiveBackgroundAudioEnabled) continue;
      if (!_sites.loaded.contains(i)) continue;
      any = true;
      break;
    }
    await BackgroundTaskService.instance.setBackgroundAudioActive(any);
    // With nothing to drive it, the media surface goes; on iOS that also
    // removes the Now Playing entry WebKit publishes for any page that plays,
    // which would outlive the audio as a control reaching nothing
    // (BGAUDIO-009/010). While a site is loaded its page reports raise it.
    if (!any) await MediaSessionService.instance.clearOsMediaSurface();
  }

  /// A notification site leaving the loaded set is checked headless by the
  /// next wake rather than reloaded (NOTIF-016, DEVTOOLS-011). Call after the
  /// removal.
  void noteUnloaded(WebViewModel m, String reason) {
    if (!m.effectiveNotificationsEnabled) return;
    final c = counts();
    BackgroundLog.instance.record(
      'SiteUnload',
      'notification site unloaded ($reason); '
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
      loadedIndices: _sites.loaded,
      isPolled: (i) => _sites.models[i].effectiveNotificationsEnabled,
    );
    var reloaded = 0;
    for (final m in [for (final i in plan.reload) _sites.models[i]]) {
      if (m.controller == null) continue;
      await m.reloadAndRepaint();
      reloaded++;
    }
    BackgroundLog.instance.record(
      'BackgroundTask',
      'refresh notif sites: reloaded=$reloaded, '
          'skipped(unloaded)=${plan.unloaded}, '
          'skipped(no controller)=${plan.reload.length - reloaded}',
    );
  }

  /// NOTIF-013/014/016: what an OS background wake runs. Returns once the
  /// checked pages have settled, which is what ends the OS task.
  Future<void> wake() async {
    final c = counts();
    BackgroundLog.instance.record(
      'BackgroundTask',
      'background wake: notif sites ${c.enabled} enabled, '
          '${c.loaded} loaded, ${c.live} with a live webview',
    );
    // A wake resumes the process without the app coming back to the
    // foreground, so the resume check tor's listener needs has not run yet
    // (TOR-024), and a Tor notification site would reload through a dead one.
    await TorService.instance.revive();
    final host = _WakeHost(_sites, _host);
    _activeWake = host;
    final WakeReport report;
    try {
      report = await _wakeEngine.wake(host);
    } finally {
      if (identical(_activeWake, host)) _activeWake = null;
    }
    for (var i = 0; i < report.sites.length; i++) {
      final o = report.sites[i];
      final line = describeWakeSite(o, i + 1, report.sites.length);
      BackgroundLog.instance.record('BackgroundTask', line.normal,
          level: o.skip == null ? LogLevel.info : LogLevel.warning,
          sensitive: line.sensitive);
    }
    BackgroundLog.instance.record(
      'BackgroundTask',
      'background wake done: ${report.count(WakeMode.live)} live, '
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
    _stopForegroundPoll();
    if (!anyNotificationSites) return;
    unawaited(BackgroundTaskService.instance.beginGracePeriod());
    _wakeEngine.forget({for (final m in _sites.models) m.siteId});
    final reads = <Future<void>>[];
    for (final i in _sites.loaded) {
      if (i < 0 || i >= _sites.models.length) continue;
      final m = _sites.models[i];
      final c = m.controller;
      if (!m.effectiveNotificationsEnabled || c == null) continue;
      reads.add(c
          .getTitle()
          .then((t) => _wakeEngine.noteBaseline(m.siteId, t))
          .catchError((_) {}));
    }
    unawaited(Future.wait(reads).then((_) => _persistBaselines()));
  }

  /// Back in the foreground: the grace window ends and the poll resumes.
  void noteResumed() {
    // A wake's headless checks end here: on Android the site the user opens
    // next moves the one process-wide proxy, and a check still loading would
    // follow it (NOTIF-016).
    unawaited(_activeWake?.closeAllHeadless());
    startForegroundPoll();
    unawaited(BackgroundTaskService.instance.endGracePeriod());
    // If memory pressure unloaded every notification site while away, the
    // schedule goes; otherwise resubmitting it is a no-op.
    unawaited(reschedule());
  }

  /// A post from the background told the user what the site's title now
  /// counts, so the next wake measures from there (NOTIF-014). Read a beat
  /// later: the page may update its title after posting.
  void _noteBaselineAfterPost(String siteId) {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    Future<void>.delayed(const Duration(seconds: 1), () async {
      // A post from a headless check (NOTIF-016) has no controller here; the
      // wake reads that page's title itself before closing it.
      final c = _sites.byId(siteId)?.controller;
      if (c == null) return;
      try {
        _wakeEngine.noteBaseline(siteId, await c.getTitle());
      } catch (_) {}
      unawaited(_persistBaselines());
    });
  }

  void _onNotificationTapped(String siteId) {
    final index = _sites.models.indexWhere((m) => m.siteId == siteId);
    if (index < 0) {
      LogService.instance.log(
        'Notification',
        'Tap for unknown siteId: $siteId',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }
    LogService.instance.log(
      'Notification',
      'Tap routing to site $index: "${_sites.models[index].name}"',
      sensitivity: LogSensitivity.sensitive,
    );
    unawaited(_host.activate(index));
    _host.rebuild();
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

  /// Startup wiring, once the sites are up: notification taps and posts,
  /// the native refresh handler, the background log's app state and the
  /// Android media transport (BGAUDIO-006).
  Future<void> install() async {
    await NotificationService.instance.init();
    NotificationService.instance.onNotificationTapped = _onNotificationTapped;
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
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed
        ? refreshSites()
        : wake();
    BackgroundTaskService.instance.initialize();
    BackgroundLog.instance.appState = () {
      final c = counts();
      final permission = NotificationService.instance.permissionGranted;
      return [
        MapEntry('app.lifecycle',
            WidgetsBinding.instance.lifecycleState?.name ?? 'unknown'),
        MapEntry('app.notificationSitesEnabled', '${c.enabled}'),
        MapEntry('app.notificationSitesLoaded', '${c.loaded}'),
        MapEntry('app.notificationSitesWithWebview', '${c.live}'),
        MapEntry('app.notificationPermission',
            permission == null ? 'not asked yet' : (permission ? 'granted' : 'denied')),
        MapEntry('app.isolation', _sites.useContainers ? 'containers' : 'legacy'),
      ];
    };
    MediaSessionService.instance.initialize();
    unawaited(reschedule());
  }

  void dispose() => _stopForegroundPoll();
}

class _WakeHost implements BackgroundWakeHost {
  _WakeHost(this._sites, this._host);

  final SiteRuntime _sites;
  final BackgroundSitesHost _host;

  /// The headless webviews this wake opened (NOTIF-016), by site.
  final Map<String, HeadlessSiteCheck> _headless = {};

  /// Set once the app is back on screen: no further check opens.
  bool _foreground = false;

  /// Android outside router mode: one proxy override for the process.
  static bool get _proxyIsGlobal =>
      hostIsAndroid && !ProxyRouterService.instance.isActive;

  @override
  List<WakeCandidate> wakeCandidates() {
    final env = WakeEnvironment(
      containers: _sites.useContainers,
      torUp: TorService.instance.status.isUp,
      proxyIsGlobal: _proxyIsGlobal,
    );
    final models = _sites.models;
    return [
      for (var i = 0; i < models.length; i++)
        wakeCandidateFor(
          models[i],
          loaded: _sites.loaded.contains(i),
          hasWebview: models[i].controller != null,
          proxyBindable: !WebViewFactory.storeBinding(models[i]
                  .sitePosture(globalUserScripts: _host.globalUserScripts))
              .proxyUnavailable,
          env: env,
        ),
    ];
  }

  // Funnelled like refreshSites: a wake can land on the visible site, and a
  // raw reload blanks it (PAUSE-021).
  @override
  Future<void> reload(String siteId) async =>
      _sites.byId(siteId)?.reloadAndRepaint();

  @override
  Future<bool> applyRoute(String siteId) async {
    final m = _sites.byId(siteId);
    if (m == null) return false;
    try {
      if (_proxyIsGlobal) {
        await ProxyManager().setProxySettings(m.proxySettings, siteId: m.siteId);
      }
      if (TorService.instance.isAvailable &&
          SiteUnloadEngine.torExitConstraint(m) != null) {
        // Tor holds its `up` status while a new pin is applied, so up again
        // means this site's exit country is in force (TOR-014).
        _host.syncTorExitPin({_sites.models.indexOf(m)});
        if (!await _torUpWithin(_torPinDeadline)) return false;
      }
      return true;
    } on Exception catch (e) {
      BackgroundLog.instance.record(
        'BackgroundTask',
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
  Future<void> releaseRoute() async {
    if (TorService.instance.isAvailable) {
      _host.syncTorExitPin({..._sites.loaded});
    }
  }

  @override
  Future<WakeSkip?> openHeadless(String siteId) async {
    final m = _sites.byId(siteId);
    if (m == null) return WakeSkip.headlessFailed;
    if (_foreground) return WakeSkip.appInForeground;
    final (check, skip) = await WebViewFactory.openHeadlessCheck(
        m.headlessCheckConfig(globalUserScripts: _host.globalUserScripts));
    if (check == null) return skip;
    if (_foreground) {
      await check.dispose();
      return WakeSkip.appInForeground;
    }
    _headless[siteId] = check;
    return null;
  }

  @override
  Future<void> closeHeadless(String siteId) async {
    await _headless.remove(siteId)?.dispose();
  }

  Future<void> closeAllHeadless() async {
    _foreground = true;
    final open = [..._headless.values];
    _headless.clear();
    for (final c in open) {
      await c.dispose();
    }
  }

  @override
  bool? isLoading(String siteId) {
    final headless = _headless[siteId];
    if (headless != null) return headless.isLoading;
    final m = _sites.byId(siteId);
    return m == null || m.controller == null ? null : m.isLoading;
  }

  @override
  Future<String?> title(String siteId) async {
    final headless = _headless[siteId];
    if (headless != null) {
      try {
        return await headless.title();
      } on PlatformException {
        return null;
      }
    }
    try {
      return await _sites.byId(siteId)?.controller?.getTitle();
    } catch (_) {
      return null;
    }
  }

  @override
  bool postedSince(String siteId, DateTime since) {
    final at = NotificationService.instance.lastPostedAt(siteId);
    return at != null && !at.isBefore(since);
  }

  @override
  Future<void> post({
    required String siteId,
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
