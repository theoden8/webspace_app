import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/settings_import_engine.dart' show promoteLegacySiteIndices;
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/theme/app_theme.dart';

/// What the cold start asks of the page.
abstract interface class StartupHost implements PageHost {
  bool get kioskLocked;
  void enterFullscreen();
  void themeChanged();

  /// [SiteRuntime.useContainers] is decided: bind the cookie jar that goes
  /// with it.
  void bindCookieJar();

  Future<void> activateRouter();
  Future<void> handleShareIntent();
}

/// The cold start: what the page loads, what it sweeps before any webview
/// binds, the site it opens, and the work [DeferredStartupEngine] runs after
/// the first paint, for which this is the host. That work addresses sites by
/// siteId and translates to a position fresh per call, so a site added or
/// deleted while it awaits can never make it act on a stale position.
class StartupController implements DeferredStartupHost {
  StartupController(
    this._sites, {
    required StartupHost host,
    required ShellStore shell,
    required SiteListStore siteStore,
    required ShortcutController shortcuts,
    required SiteActivationController activation,
    required BackgroundSitesController background,
    required PageOrphanSweep sweep,
  }) : _host = host,
       _shell = shell,
       _siteStore = siteStore,
       _shortcuts = shortcuts,
       _activation = activation,
       _background = background,
       _sweep = sweep;

  final SiteRuntime _sites;
  final StartupHost _host;
  final ShellStore _shell;
  final SiteListStore _siteStore;
  final ShortcutController _shortcuts;
  final SiteActivationController _activation;
  final BackgroundSitesController _background;
  final PageOrphanSweep _sweep;

  Future<void> restore() async {
    final activationVersionAtRestore = _sites.activationVersion;
    final swRestore = kDebugMode ? (Stopwatch()..start()) : null;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    _shell.loadTheme(prefs);
    _shortcuts.load(prefs);
    _host.themeChanged();
    _host.rebuild();
    await _shell.loadWebspaces();
    _host.rebuild();
    await _shell.loadGlobalUserScripts();
    // Before the sites are committed: whether hosted tabs can exist at all
    // depends on the engine (LIR-019), and the commit settles them. Every
    // path downstream branches on it synchronously. False on Android System
    // WebView without MULTI_PROFILE, iOS <17, macOS <14 and unsupported
    // platforms.
    _sites.useContainers = await ContainerNative.instance.isSupported();
    _host.bindCookieJar();
    LogTag.container.debug(
      _sites.useContainers
          ? 'Container API supported — using ContainerIsolationEngine + ContainerCookieManager'
          : 'Container API not supported — using CookieIsolationEngine + (legacy) CookieManager',
    );
    final (sites: restored, :needsResave) = await _siteStore.load(
      onChange: _host.rebuild,
    );
    if (swRestore != null) {
      LogTag.startup.debug(
        'load ${restored.length} site(s) + cookies: ${swRestore.elapsedMilliseconds}ms',
      );
    }
    // Legacy positional membership resolves against the restored order,
    // before the commit rebuilds every webspace's positions from siteIds.
    if (promoteLegacySiteIndices(_sites.webspaces, sites: restored)) {
      await _shell.saveWebspaces();
    }
    // Sites restored with ProxyType.TOR need the runtime coming up before
    // their first navigation, or each opens on the bootstrap interstitial;
    // the commit's Tor sync does that.
    await _host.commitSites(SitesLoaded(restored));
    if (await _shell.migrateGlobalScriptOptIn()) {
      await _host.commitSites(const SitesEdited());
    }
    _shell.suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

    await _host.activateRouter();

    // Startup GC. The container sweeps run here (before any WebView binds —
    // `deleteContainer` is only reliable in that unbound window). The
    // secure-storage / HTML / cookie-jar sweeps are pure housekeeping for
    // sites deleted in previous sessions, so they're deferred until after the
    // launched site has painted (see `runPostPaintMaintenance` below): the
    // activated site reads its cookies from its already-hydrated model (legacy
    // mode re-nukes + restores the jar inside `_restoreCookiesForSite`;
    // container mode reads from its own container), so none of those sweeps is
    // on the first-paint path.
    final activeSiteIdsAtStartup = _sites.models.map((m) => m.siteId).toSet();
    await _shortcuts.pruneAgainst(activeSiteIdsAtStartup);
    // Incognito sites are treated as orphans for any session-scoped GC
    // (cookies, html cache, navigation state, container) so on-disk
    // remnants don't outlive the process — see issue #298. Their config
    // (proxy passwords, imported HTML for file:// sites) stays put.
    final nonIncognitoSiteIds = {
      for (final m in _sites.models)
        if (!m.incognito) m.siteId,
    };
    await _sweep.containersBeforeBind(
      activeSiteIdsAtStartup,
      nonIncognitoSiteIds: nonIncognitoSiteIds,
    );
    // Left uninitialised in demo mode, which keeps the store memory-only
    // there.
    if (!isDemoMode) {
      unawaited(SiteIconStore.instance.initialize());
    }

    // Every launch starts on the webspace list unless a shortcut names a site.
    final indexToRestore = await _shortcuts.resolveColdLaunch();
    if (!_host.mounted) return;

    // Notification sites auto-load so they poll and fire notifications without
    // the user opening them. In container mode this is deferred to AFTER the
    // launched site paints (below) so a large notif import doesn't block the
    // shortcut target. In legacy (non-container) mode they must load pre-paint
    // so `setCurrentIndex`'s conflict-unload can arbitrate same-base-domain
    // collisions; preload each one's HTML so its first build's getHtmlSync hits.
    if (!_sites.useContainers && !launchedForBackgroundWake) {
      for (int i = 0; i < _sites.models.length; i++) {
        if (_sites.models[i].effectiveNotificationsEnabled) {
          await _activation.ensureSiteHtml(i);
          // PAUSE-019: same pre-queue as the container-mode deferred
          // path — once in _sites.loaded the activation restore is
          // skipped, so the back/forward stack must be queued now.
          await queueNavStateRestore(_sites.models[i].siteId);
          _sites.loaded.add(i);
        }
      }
    }

    // Apply saved theme BEFORE setCurrentIndex so the first build sees the
    // right currentTheme — initialHtml reads it to pick the dark prelude for
    // cached HTML (file:// imports especially, which never reload to live and
    // so paint with whatever prelude the first build chose). Models default to
    // WebViewTheme.light, so without this the first frame on a dark theme
    // flashes white before the controller is created and re-applies via
    // setController(). Only the models built this frame (launched site + any
    // auto-loaded notification sites) need it now; the rest are themed after
    // paint — their controllers aren't created until activated, and
    // setController re-applies the theme then.
    final webViewTheme = _shell.theme.themeMode.webViewTheme;
    final preThemeIndices = <int>{..._sites.loaded, ?indexToRestore};
    for (final i in preThemeIndices) {
      if (i >= 0 && i < _sites.models.length) {
        await _sites.models[i].setTheme(webViewTheme);
      }
    }

    // Parity: a launched from-location site whose timezone hasn't been baked
    // into `spoofTimezone` yet (data saved before tz-baking existed) must still
    // spoof tz on this launch, matching the old resolve-at-build behavior. The
    // background `_refreshLocationTimezones` would only fix it next launch, so
    // resolve it synchronously here — but only for the launched site, only when
    // unbaked, so the polygon dataset stays off the path for everyone else.
    if (indexToRestore != null) {
      final m = _sites.models[indexToRestore];
      final unbaked = m.spoofTimezone == null || m.spoofTimezone!.isEmpty;
      if (unbaked &&
          derivesTimezoneFromLocation(
            spoofTimezoneFromLocation: m.spoofTimezoneFromLocation,
            trackingProtectionEnabled: m.trackingProtectionEnabled,
            spoofLatitude: m.spoofLatitude,
            spoofLongitude: m.spoofLongitude,
          )) {
        if (await TimezoneLocationService.instance.loadFromCacheIfPresent()) {
          final tz = TimezoneLocationService.instance.lookup(
            m.spoofLatitude!,
            longitude: m.spoofLongitude!,
          );
          if (tz != null) m.spoofTimezone = tz;
        }
      }
    }

    final swActivate = kDebugMode ? (Stopwatch()..start()) : null;
    if (StartupRestoreEngine.shouldActivateAfterRestore(
      indexToRestore: indexToRestore,
      activatedDuringRestore:
          _sites.activationVersion != activationVersionAtRestore,
    )) {
      await _activation.setCurrentIndex(indexToRestore);
    }
    if (swActivate != null) {
      LogTag.startup.debug(
        'activate target site (setCurrentIndex): ${swActivate.elapsedMilliseconds}ms',
      );
    }
    if (!_host.mounted) return;
    // indexToRestore is non-null only for a shortcut cold launch, so apply
    // the FS-008 shortcut-launch fullscreen policy here.
    // KIOSK-003: a locked kiosk launch always goes fullscreen, overriding the
    // per-site / fullscreenOnShortcut policy.
    if (indexToRestore != null &&
        (_host.kioskLocked ||
            StartupRestoreEngine.shouldEnterFullscreen(
              viaShortcut: true,
              fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
              perSiteFullscreenMode:
                  _sites.models[indexToRestore].fullscreenMode,
            ))) {
      _host.enterFullscreen();
    }
    _host.rebuild();
    if (swRestore != null) {
      LogTag.startup.debug(
        'restore to first setState (total): ${swRestore.elapsedMilliseconds}ms',
      );
    }

    // Container mode: auto-load notification sites now that the launched site
    // has painted — off the first-frame path. Each one's cached/imported HTML
    // is decrypted before it enters _sites.loaded so its build's getHtmlSync
    // hits; doing it here keeps a large notif import from blocking the shortcut
    // target's first paint. (Legacy mode already loaded them pre-paint above.)
    if (_sites.useContainers && !launchedForBackgroundWake) {
      unawaited(
        DeferredStartupEngine.autoLoadNotificationSites(
          this,
        ).then((_) => _background.reschedule()),
      );
    }

    // Off the first-paint path: theme the remaining (not-yet-built) models,
    // persist the load-time migration, and sweep orphan storage — all behind
    // the siteId-keyed DeferredStartupEngine so a post-paint add/delete can't
    // race it (see test/deferred_startup_engine_test.dart). The launched site
    // waits on none of it.
    final preThemeSiteIds = <String>{
      for (final i in preThemeIndices)
        if (i >= 0 && i < _sites.models.length) _sites.models[i].siteId,
    };
    unawaited(
      DeferredStartupEngine.runPostPaintMaintenance(
        this,
        alreadyThemedSiteIds: preThemeSiteIds,
        needsResave: needsResave,
      ),
    );

    _shortcuts.promptParkedAfterFrame();

    // Refresh the iOS App Intents picker on every launch, not just on save.
    // iOS queries `suggestedEntities()` (and may re-materialize the per-site
    // App Shortcuts) whenever Shortcuts.app is touched; if the App Group was
    // never repopulated this session it can serve a stale single entry whose
    // bound target no longer matches its title. Re-syncing here also re-fires
    // `updateAppShortcutParameters()` so iOS re-reads the current site list.
    _shortcuts.syncSites();

    _background.startForegroundPoll();

    // Off the cold-start critical path. Neither gates the first frame or the
    // launched site: the image cache's upgrade-clear only matters on a version
    // bump, and the favicon URL cache is consulted progressively by the tab
    // strip / add-site UI (a miss just triggers a fresh fetch).
    unawaited(ImageCacheService.clearCacheOnUpgrade());
    unawaited(FaviconUrlCache.initialize());

    // Off the cold-start critical path: re-resolve the persisted timezone for
    // any from-location site (migrates sites saved before the tz was baked
    // into `spoofTimezone`, and refreshes after a dataset update). The dataset
    // load + parse happen on a background isolate after the first frame.
    unawaited(DeferredStartupEngine.refreshLocationTimezones(this));

    await _background.install();
    // Cold-start path for share intents; the resume handles the warm one.
    unawaited(_host.handleShareIntent());
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
  bool isLive(String siteId) => _sites.byId(siteId) != null;

  @override
  bool isLoaded(String siteId) {
    final i = _sites.models.indexWhere((m) => m.siteId == siteId);
    return i >= 0 && _sites.loaded.contains(i);
  }

  @override
  void markLoaded(String siteId) {
    final i = _sites.models.indexWhere((m) => m.siteId == siteId);
    if (i >= 0) _sites.loaded.add(i);
  }

  @override
  Future<void> preloadHtml(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) await _activation.ensureSiteHtmlForModel(m);
  }

  @override
  Future<void> applyTheme(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) {
      await m.setTheme(_shell.theme.themeMode.webViewTheme);
    }
  }

  /// PAUSE-019: see [SiteActivationController.queueRestoreFor].
  @override
  Future<void> queueNavStateRestore(String siteId) =>
      _activation.queueRestoreFor(siteId);

  @override
  void requestRebuild() => _host.rebuild();

  @override
  Future<bool> loadTimezoneDataset() =>
      TimezoneLocationService.instance.loadFromCacheIfPresent();

  @override
  String? resolveTimezone(double latitude, {required double longitude}) =>
      TimezoneLocationService.instance.lookup(latitude, longitude: longitude);

  @override
  bool setSpoofTimezone(String siteId, {required String timezone}) {
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
  Set<String> liveSiteIds() => _sites.siteIds;

  @override
  Set<String> liveNonIncognitoSiteIds() => _sites.nonIncognitoSiteIds;

  @override
  Future<void> sweepOrphanStorage(
    Set<String> activeSiteIds, {
    required Set<String> nonIncognitoSiteIds,
  }) =>
      _sweep.atLaunch(activeSiteIds, nonIncognitoSiteIds: nonIncognitoSiteIds);
}
