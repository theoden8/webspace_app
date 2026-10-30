import 'dart:async';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/controllers/site_network_controller.dart'
    show LaunchedSite;
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/launch_timeline.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings_import_engine.dart' show promoteLegacySiteIndices;
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/webview_proxy.dart' show ProxyManager;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/web_view_model.dart';

/// What the cold start asks of the page.
abstract interface class StartupHost implements PageHost {
  bool get kioskLocked;
  void enterFullscreen();
  void themeChanged();

  /// The legacy engine, which the restore binds where containers are not
  /// supported.
  CookieIsolationEngine get legacyJar;

  Future<void> activateRouter({required LaunchedSite launch});
  Future<void> handleShareIntent({required Reached<Launched> after});
}

/// A fact of the launch, as a type: holding a [Reached] of one is the proof
/// that it holds, and a call that needs the fact takes the proof. A later
/// phase extends what it implies, so its proof stands in for theirs.
sealed class LaunchPhase {}

abstract final class PrefsLoaded extends LaunchPhase {}

/// The webspaces and the global user scripts.
abstract final class ShellLoaded extends LaunchPhase {}

/// The restored sites are on the page, their zones resolved and their
/// script opt-in migrated: the grid shows them and takes taps.
abstract final class SitesOnPage extends LaunchPhase {}

/// The launched site's activation has ended, or the list is shown.
abstract final class Launched extends SitesOnPage {}

/// Proof that [P] has been reached. Only the restore makes one, and a test
/// that stands in for it.
final class Reached<P extends LaunchPhase> {
  const Reached._();

  @visibleForTesting
  const Reached.inTest();
}

typedef _Loaded = ({List<WebViewModel> sites, bool needsResave});

/// The site a shortcut or a tapped notification names, held by identity.
typedef _LaunchTarget = ({WebViewModel? shortcutSite, WebViewModel? site});

/// The cold start: what the page loads, what it sweeps before any webview
/// binds, the site it opens, and the work [DeferredStartupEngine] runs after
/// the first paint, for which this is the host. That work addresses sites by
/// siteId and translates to a position fresh per call, so a site added or
/// deleted while it awaits can never make it act on a stale position.
class StartupController implements DeferredStartupHost {
  StartupController(
    this._sites, {
    required ProcessLaunch launch,
    required StartupHost host,
    required ShellStore shell,
    required SiteListStore siteStore,
    required ShortcutController shortcuts,
    required SiteActivationController activation,
    required BackgroundSitesController background,
    required PageOrphanSweep sweep,
  }) : _launch = launch,
       _host = host,
       _shell = shell,
       _siteStore = siteStore,
       _shortcuts = shortcuts,
       _activation = activation,
       _background = background,
       _sweep = sweep;

  final SiteRuntime _sites;
  final ProcessLaunch _launch;
  final StartupHost _host;
  final ShellStore _shell;
  final SiteListStore _siteStore;
  final ShortcutController _shortcuts;
  final SiteActivationController _activation;
  final BackgroundSitesController _background;
  final PageOrphanSweep _sweep;

  final _launched = Completer<Reached<Launched>?>();

  /// The launched site's activation has ended; null when the restore gave up
  /// before it, which it logged. A resume needs the proof for what the cold
  /// launch would undo (a warm shortcut, a share intent).
  Future<Reached<Launched>?> launched() => _launched.future;

  /// Each step takes the proofs of the steps it follows and returns its own,
  /// so a step called before its prerequisites does not compile; steps that
  /// take nothing in common run at once.
  Future<void> restore() async {
    final activationVersionAtRestore = _sites.activationVersion;
    try {
      final prefs = _loadPrefs();
      final shell = _loadShell();
      final isolation = _bindIsolation();
      final loaded = _loadSites();
      final icons = isDemoMode
          ? Future<void>.value()
          : SiteIconStore.instance.initialize();
      final swept = _sweepContainers(await isolation, loaded: await loaded);
      final onPage = await _putSitesOnPage(
        prefs: await prefs,
        shell: await shell,
        isolation: await isolation,
        loaded: await loaded,
      );
      if (onPage == null) return;
      LaunchTimeline.reached(LaunchMark.sitesOnPage);
      final suggested = _loadSuggestedSites(after: await prefs);
      final launching = _shortcuts
          .pruneAgainst(_sites.siteIds, after: onPage)
          .then((_) {
        LaunchTimeline.reached(LaunchMark.shortcutsPruned);
        return _launchTarget(after: onPage);
      });
      final routes = _host.activateRouter(launch: (
        site: launching.then((target) => target?.site),
        settled: _launched.future.then((_) => launchedSiteLoaded()),
      ));
      final target = await launching;
      if (target == null) return;
      LaunchTimeline.reached(LaunchMark.launchTarget);
      final pins = _shortcuts.refreshPinned(after: onPage);
      final themed = await _themeLaunch(target, prefs: await prefs);
      LaunchTimeline.reached(LaunchMark.themed);
      await routes;
      LaunchTimeline.reached(LaunchMark.routes);
      final launched = await _activate(
        target,
        themed: themed,
        activationVersionAtRestore: activationVersionAtRestore,
      );
      if (launched == null) return;
      _launched.complete(launched);
      unawaited(_reportLaunch());
      // Not awaited before the launch: a container the activation makes waits
      // for the sweep on its own (CONT-004).
      await Future.wait([
        icons,
        suggested,
        pins,
        swept,
        _afterLaunch(launched, themed: themed, loaded: await loaded),
      ]);
    } finally {
      if (!_launched.isCompleted) _launched.complete(null);
    }
  }

  Future<Reached<PrefsLoaded>> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    // Before any icon draws: one that finds no kept URL searches the site.
    await FaviconUrlCache.initialize();
    _shell.loadTheme(prefs);
    _shortcuts.load(prefs);
    _host.themeChanged();
    _host.rebuild();
    LaunchTimeline.reached(LaunchMark.prefsLoaded);
    return const Reached._();
  }

  Future<Reached<ShellLoaded>> _loadShell() async {
    await _shell.loadWebspaces();
    _host.rebuild();
    await _shell.loadGlobalUserScripts();
    LaunchTimeline.reached(LaunchMark.shellLoaded);
    return const Reached._();
  }

  /// Before the sites are committed: whether hosted tabs can exist at all
  /// depends on the engine (LIR-019), and the commit settles them. On the
  /// shared jar the launch clear is queued before this returns (ISO-012).
  Future<Isolation> _bindIsolation() async {
    final decided = await Isolation.probe(
      native: ContainerNative.instance,
      legacy: () => _host.legacyJar,
    );
    final isolation = _sites.isolation = decided;
    ProxyManager.decideBinding(isolation);
    // Queued before the commit makes the grid tappable, so it is the jar's
    // first turn and every restore waits behind it (ISO-003).
    if (isolation case SharedJar(:final jar)) {
      // A jar that refuses is left as it is: the next activation empties it
      // before any site shows (ISO-012), and the launch goes on.
      final cleared = jar.clearUnloaded(loaded: _sites.loaded);
      unawaited(
        cleared.catchError(
          (Object e) => LogTag.startup.warning('Launch jar clear failed: $e'),
          test: (e) => e is CookieJarFailure,
        ),
      );
    }
    LogTag.container.debug(switch (isolation) {
      Containers() =>
        'Container API supported — using ContainerIsolationEngine + ContainerCookieManager',
      SharedJar() =>
        'Container API not supported — using CookieIsolationEngine + (legacy) CookieManager',
    });
    LaunchTimeline.reached(LaunchMark.isolationProbed);
    return isolation;
  }

  Future<_Loaded> _loadSites() async {
    final loaded = await _siteStore.load(onChange: _host.rebuild);
    LaunchTimeline.reached(LaunchMark.sitesLoaded);
    return loaded;
  }

  /// The sweep of containers no site will bind, started before the sites are
  /// committed so it is under way before the grid can make one: a container
  /// bound first is one `deleteContainer` cannot reliably remove (CONT-004).
  /// Incognito sites are orphans for any session-scoped GC, so their
  /// containers do not outlive the process (#298).
  Future<void> _sweepContainers(
    Isolation isolation, {
    required _Loaded loaded,
  }) => switch (isolation) {
    Containers(:final engine) => engine.sweepBeforeBind(
      {for (final m in loaded.sites) m.containerKey},
      incognito: {
        for (final m in loaded.sites)
          if (m.incognito) m.containerKey,
      },
    ),
    SharedJar() => Future<void>.value(),
  };

  /// The sites committed: the grid shows them and takes taps from here.
  /// Null once the page has gone.
  Future<Reached<SitesOnPage>?> _putSitesOnPage({
    required Reached<PrefsLoaded> prefs,
    required Reached<ShellLoaded> shell,
    required Isolation isolation,
    required _Loaded loaded,
  }) async {
    if (!_host.mounted) return null;
    // Against the restored order, before the commit rebuilds every
    // webspace's positions from siteIds.
    if (promoteLegacySiteIndices(_sites.webspaces, sites: loaded.sites)) {
      await _shell.saveWebspaces();
    }
    // Sites restored with ProxyType.TOR need the runtime coming up before
    // their first navigation, or each opens on the bootstrap interstitial;
    // the commit's Tor sync does that.
    await _host.commitSites(SitesLoaded(loaded.sites));
    if (await _shell.migrateGlobalScriptOptIn()) {
      await _host.commitSites(const SitesEdited());
    }
    return _host.mounted ? const Reached._() : null;
  }

  Future<void> _loadSuggestedSites({
    required Reached<PrefsLoaded> after,
  }) async {
    _shell.suggestedSites = await suggested_sites.loadSuggestedSites();
  }

  /// Every launch starts on the webspace list unless a shortcut or the
  /// notification the user tapped names a site, held by identity from here:
  /// the grid takes edits while the restore awaits.
  Future<_LaunchTarget?> _launchTarget({
    required Reached<SitesOnPage> after,
  }) async {
    final shortcutSite = await _shortcuts.resolveColdLaunch(after: after);
    if (!_host.mounted) return null;
    final tappedSite = await _background.wireTaps();
    if (!_host.mounted) return null;
    return (shortcutSite: shortcutSite, site: shortcutSite ?? tappedSite);
  }

  /// Before the activation so its first build sees the right theme:
  /// initialHtml picks the dark prelude for a file import from it, and
  /// models default to light, so a dark theme would otherwise flash white. Only the models built now need it;
  /// the rest are themed after paint. Returns their siteIds.
  Future<Set<SiteId>> _themeLaunch(
    _LaunchTarget target, {
    required Reached<PrefsLoaded> prefs,
  }) async {
    final webViewTheme = _shell.theme.themeMode.webViewTheme;
    final models = <WebViewModel>{..._sites.loaded, ?target.site};
    for (final m in models) {
      await m.setAppTheme(webViewTheme);
    }
    return {for (final m in models) m.siteId};
  }

  /// The launched site activated, or the list shown, and the shortcut's
  /// fullscreen policy. Null once the page has gone.
  Future<Reached<Launched>?> _activate(
    _LaunchTarget target, {
    required Set<SiteId> themed,
    required int activationVersionAtRestore,
  }) async {
    final launchAt = switch (target.site) {
      final m? when _sites.models.contains(m) => m,
      _ => null,
    };
    _launchedSite = launchAt;
    if (StartupRestoreEngine.shouldActivateAfterRestore(
      opensSite: launchAt != null,
      activatedDuringRestore:
          _sites.activationVersion != activationVersionAtRestore,
    )) {
      await _activation.activate(launchAt);
    }
    LaunchTimeline.reached(LaunchMark.activated);
    if (!_host.mounted) return null;
    // The FS-008 shortcut-launch fullscreen policy; a notification launch is
    // not a shortcut and opens the site as a tap would. KIOSK-003: a locked
    // kiosk launch always goes fullscreen.
    if (target.shortcutSite case final site?
        when _sites.byId(site.siteId) != null &&
            (_host.kioskLocked ||
                StartupRestoreEngine.shouldEnterFullscreen(
                  viaShortcut: true,
                  fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
                  perSiteFullscreenMode: site.fullscreenMode,
                ))) {
      _host.enterFullscreen();
    }
    _host.rebuild();
    return const Reached._();
  }

  /// The launch's timeline, once the launched page has settled or is no
  /// longer waited for (DEVTOOLS-013).
  Future<void> _reportLaunch() async {
    final site = _launchedSite;
    if (site != null) {
      unawaited(site.firstLoadSettled
          .then((_) => LaunchTimeline.reached(LaunchMark.pageSettled)));
      await launchedSiteLoaded();
    }
    LaunchTimeline.end();
  }

  /// Off the first paint: what the launched site waits on none of.
  Future<void> _afterLaunch(
    Reached<Launched> launched, {
    required Set<SiteId> themed,
    required _Loaded loaded,
  }) {
    _launchedProof = launched;
    final themeRest = DeferredStartupEngine.themeRemaining(
      this,
      alreadyThemedSiteIds: themed,
    );
    final background = _background.install();
    _shortcuts.promptParkedAfterFrame();
    // Every launch, not just on save: iOS queries `suggestedEntities()`
    // whenever Shortcuts.app is touched, and an App Group not repopulated
    // this session can serve a stale entry whose bound target no longer
    // matches its title.
    _shortcuts.syncSites();
    _background.startForegroundPoll();
    return Future.wait([
      themeRest,
      background,
      // Notification sites auto-load so they poll and notify without the
      // user opening them, themed and with their posts wired. Each is a
      // preload: on the shared jar its session is restored before its
      // webview is built, and it yields to a same-domain site already loaded
      // (ISO-001).
      Future.wait([themeRest, background]).then((_) async {
        switch (_launch) {
          case ProcessLaunch.user:
            await DeferredStartupEngine.autoLoadNotificationSites(this);
          case ProcessLaunch.backgroundWake:
            // The wake checks them headless (NOTIF-016).
        }
      }),
      DeferredStartupEngine.persistAndSweep(
        this,
        needsResave: loaded.needsResave,
      ),
      ImageCacheService.clearCacheOnUpgrade(),
      // Migrates sites saved before the tz was baked into `spoofTimezone`,
      // and refreshes after a dataset update. The dataset parses on a
      // background isolate.
      DeferredStartupEngine.refreshLocationTimezones(this),
      // Cold-start path for share intents; the resume handles the warm one.
      _host.handleShareIntent(after: launched),
    ]);
  }

  @override
  List<DeferredSite> currentSites() => [
    for (final m in _sites.models)
      DeferredSite(
        siteId: m.siteId,
        notificationsEnabled: m.effectiveNotificationsEnabled,
        spoofTimezoneFromLocation: m.spoofTimezoneFromLocation,
        trackingProtectionEnabled: m.trackingProtectionEnabled,
        spoofLatitude: m.spoofLatitude,
        spoofLongitude: m.spoofLongitude,
      ),
  ];

  @override
  bool get isMounted => _host.mounted;

  @override
  bool isLive(SiteId siteId) => _sites.byId(siteId) != null;

  /// The launch, for the preloads it starts: set once, by [_afterLaunch].
  late final Reached<Launched> _launchedProof;

  @override
  Future<PreloadOutcome> preload(SiteId siteId) =>
      _activation.preload(siteId, after: _launchedProof);

  @override
  Future<void> activationSettled() => _sites.activationSettled();

  /// The site a shortcut or a notification opened at launch, once the
  /// restore has activated it.
  WebViewModel? _launchedSite;

  /// Completes when the page goes, so no wait it started outlives it.
  final Completer<void> _disposed = Completer<void>();

  void dispose() {
    if (!_disposed.isCompleted) _disposed.complete();
  }

  @override
  Future<void> launchedSiteLoaded() async {
    final site = _launchedSite;
    if (site == null) return;
    final cap = Completer<void>();
    final timer = Timer(kLaunchLoadWait, cap.complete);
    try {
      await Future.any(
          [site.firstLoadSettled, cap.future, _disposed.future]);
    } finally {
      timer.cancel();
    }
  }

  @override
  Future<void> applyTheme(SiteId siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) {
      await m.setAppTheme(_shell.theme.themeMode.webViewTheme);
    }
  }

  @override
  Future<bool> loadTimezoneDataset() =>
      TimezoneLocationService.instance.loadFromCacheIfPresent();

  @override
  String? resolveTimezone(double latitude, {required double longitude}) =>
      TimezoneLocationService.instance.lookup(latitude, longitude: longitude);

  @override
  bool setSpoofTimezone(SiteId siteId, {required String timezone}) {
    final m = _sites.byId(siteId);
    if (m != null && m.spoofTimezone != timezone) {
      m.spoofTimezone = timezone;
      return true;
    }
    return false;
  }

  @override
  Future<void> persist() => _host.commitSites(const SitesEdited());

  @override
  Set<SiteId> liveSiteIds() => _sites.siteIds;

  @override
  Set<SiteId> liveNonIncognitoSiteIds() => _sites.nonIncognitoSiteIds;

  @override
  Future<void> sweepOrphanStorage(
    Set<SiteId> activeSiteIds, {
    required Set<SiteId> nonIncognitoSiteIds,
  }) =>
      _sweep.atLaunch(activeSiteIds, nonIncognitoSiteIds: nonIncognitoSiteIds);
}
