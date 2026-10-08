import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/controllers/app_lifecycle_controller.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/deferred_startup_controller.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/controllers/fullscreen_controller.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_editing_controller.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/site_editing_prompts.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/site_list_menu.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/site_tab_strip.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/archive.dart' show ArchiveHandle;
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/site_data_clear_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/nav_state_capture_debouncer.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/nested_open_engine.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/site_webview_stack.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/link_menu_sheet.dart';
import 'package:webspace/widgets/archive_prompts.dart';
import 'package:webspace/widgets/backup_prompts.dart';
import 'package:webspace/widgets/link_prompts.dart';
import 'package:webspace/widgets/page_load_bar.dart';
import 'package:webspace/widgets/protection_shield_button.dart';
import 'package:webspace/widgets/theme_mode_button.dart';
import 'package:webspace/widgets/shortcut_prompts.dart';
import 'package:webspace/widgets/surface_nudge_scope.dart';
import 'package:webspace/widgets/webspace_prompts.dart';
import 'package:webspace/widgets/webview_prompts.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/webview_controller.dart';

/// Test seam: when set, the page state uses this store instead of
/// constructing a [SecureWebViewStateStorage]. Lets integration tests
/// inject an in-memory store that survives a simulated restart (re-run of
/// [main]) without a platform keychain backend.
@visibleForTesting
WebViewStateStorage? debugWebViewStateStorageOverride;

/// Test seam: live reference to the current run's loaded site models, so
/// integration tests can reach a webview controller (URL, back/forward,
/// restore state) the widget tree doesn't otherwise expose.
@visibleForTesting
List<WebViewModel>? debugWebViewModels;

class WebSpacePage extends StatefulWidget {
  final Function(AppThemeSettings) onThemeSettingsChanged;

  WebSpacePage({required this.onThemeSettingsChanged});

  @override
  _WebSpacePageState createState() => _WebSpacePageState();
}

class _WebSpacePageState extends State<WebSpacePage>
    with WidgetsBindingObserver, RouteAware {
  final SiteRuntime _sites = SiteRuntime();
  late final ShortcutController _shortcuts = ShortcutController(_sites,
      host: _PageHost(this), prompts: DialogShortcutPrompts(context));
  late final SurfaceRepaintController _surface = SurfaceRepaintController(
    _PageHost(this),
    repaints: hostIsAndroid,
    traceSuffix: '',
  );
  late final FullscreenController _fullscreen =
      FullscreenController(host: _PageHost(this), surface: _surface);
  late final SiteActivationController _activation = SiteActivationController(
    _sites,
    host: _PageHost(this),
    residency: _ResidencyHost(this),
    navStates: _stateStorage,
    containers: _containerIsolation,
    surface: _surface,
  );
  late final BackgroundSitesController _background =
      BackgroundSitesController(_sites, host: _PageHost(this));
  late final AppLifecycleController _lifecycle = AppLifecycleController(
    _sites,
    host: _PageHost(this),
    surface: _surface,
    shortcuts: _shortcuts,
    background: _background,
    cookies: _cookieManager,
  );
  late final SiteNetworkController _network = SiteNetworkController(
    _sites,
    host: _PageHost(this),
    residency: _ResidencyHost(this),
    background: _background,
    containers: _containerIsolation,
  );
  late final TabsController _tabs = TabsController(
    _sites,
    host: _PageHost(this),
    navStates: _stateStorage,
    residency: _ResidencyHost(this),
  );
  late final LinkController _links = LinkController(
    _sites,
    host: _PageHost(this),
    prompts: DialogLinkPrompts(context),
    tabs: _tabs,
  );
  late final WebspacesController _webspaces = WebspacesController(
    _sites,
    host: _PageHost(this),
    prompts: DialogWebspacePrompts(context),
    shell: _shell,
    activation: _activation,
  );
  late final SiteEditingController _editing = SiteEditingController(
    _sites,
    host: _PageHost(this),
    prompts: DialogSiteEditingPrompts(context,
        shell: _shell, applyTheme: _applyThemeSettings),
    shell: _shell,
    shortcuts: _shortcuts,
  );
  late final PageOrphanSweep _sweep = PageOrphanSweep(
    _sites,
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
    cookies: _cookieManager,
  );
  late final DeferredStartupController _deferred = DeferredStartupController(
    _sites,
    host: _PageHost(this),
    shell: _shell,
    activation: _activation,
    navStates: _stateStorage,
    sweep: _sweep,
  );
  late final BackupController _backup = BackupController(
    _sites,
    host: _PageHost(this),
    prompts: DialogBackupPrompts(context),
    shell: _shell,
    archives: _archives,
    background: _background,
    cookies: _cookieManager,
  );
  late final ArchiveController _archives = ArchiveController(
    _sites,
    host: _PageHost(this),
    prompts: DialogArchivePrompts(context),
    containers: _containerIsolation,
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
  );
  late final ShellStore _shell = ShellStore(_sites);
  final CookieManager _cookieManager = CookieManager();
  final CookieSecureStorage _cookieSecureStorage = CookieSecureStorage();
  late final SiteListStore _siteStore = SiteListStore(
    cookies: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
  );
  final ProxyPasswordSecureStorage _proxyPasswordStorage =
      ProxyPasswordSecureStorage();
  late final CookieIsolationEngine _cookieIsolation = CookieIsolationEngine(
    cookieManager: _cookieManager,
    storage: _cookieSecureStorage,
  );
  late final ContainerIsolationEngine _containerIsolation =
      ContainerIsolationEngine(containerNative: ContainerNative.instance);

  /// Container-mode cookie manager. Non-null when `_sites.useContainers ==
  /// true`; null in legacy mode (the existing `_cookieManager` covers
  /// that path). Resolved alongside `_sites.useContainers` in
  /// `_restoreAppState` so the branches stay tied to the same
  /// runtime decision. The WebViewModel cookie-blocking path branches
  /// on `containerCookieManager != null`.
  late final ContainerCookieManager? _containerCookieManager;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final _backGuard = ReentryGuard();
  final _siteSettingsGuard = ReentryGuard();
  bool _isFindVisible = false;
  /// When true, a full-screen opaque mask covers every webview so the
  /// OS task-switcher / recents snapshot doesn't capture archive-tier
  /// content (ARCH-009). Set on `inactive`/`paused` when at least one
  /// archive is open; cleared on `resumed`. Apps without an open
  /// archive get the normal screenshot.
  bool _maskBackground = false;
  // NAV-009: what the back gesture does at the start of a site's history.
  // Off by default — the gesture only walks webview history (issue #369);
  // turning it on opens the drawer there, and again to leave the app (#431).
  // Pinned off where the setting is not offered.
  BackAtHistoryStart get _backAtHistoryStart =>
      _backAtHistoryStartOffered && AppPref.backOpensMenu.value
          ? BackAtHistoryStart.openMenu
          : BackAtHistoryStart.ignore;
  bool get _backAtHistoryStartOffered => backAtHistoryStartConfigurable(
        isIOS: hostIsIOS,
        isMacOS: hostIsMacOS,
      );
  // True while the drawer showing is the one the back gesture itself opened.
  // Only that drawer escalates to leaving the app on the next gesture.
  bool _drawerOpenedByBackGesture = false;

  // Drops concurrent `_handleMemoryPressure` invocations. The OS may
  // fire `didHaveMemoryPressure` repeatedly under sustained pressure;
  // the first handler runs to completion, then the next event picks up
  // the new state. Without this, in legacy (non-container) mode the
  // capture-then-dispose await window lets two handlers pick the same
  // victim and double-write its captured cookies to storage.
  final _memoryPressureGuard = ReentryGuard();

  // AES-encrypted on-disk storage for per-site `controller.saveState()`
  // bytes. The same encryption pattern as the HTML cache: a 256-bit
  // AES key in `FlutterSecureStorage`, per-site files under
  // `<docs>/webview_state/<siteId>.enc`. Bytes survive webspace
  // switches, LRU evictions, memory-pressure disposals, AND cold
  // starts (cleared on app-version upgrade alongside the key).
  //
  // Sites in [SiteLifecycleState.savedForRestore] have an entry here
  // keyed by siteId; re-activation reads it and pre-populates the
  // model's `_pendingRestoreState` so onControllerCreated can apply
  // it to the freshly-built controller.
  final WebViewStateStorage _stateStorage =
      debugWebViewStateStorageOverride ?? SecureWebViewStateStorage();

  // Trailing-edge debounce for navigation-driven state captures
  // (PAUSE-009): one saveState() IPC per navigation burst, fired after
  // the burst settles, so the on-disk back/forward stack stays fresh
  // for kill paths that never deliver `paused` (app-switcher
  // swipe-kill) and for background sites navigating while another site
  // is current.
  final ScreenCaptureGuard _screenCaptureGuard = ScreenCaptureGuard();
  final NavStateCaptureDebouncer _navStateDebouncer =
      NavStateCaptureDebouncer();

  // KIOSK-002: set when the current session entered via a home-shortcut tap
  // targeting a kiosk-mode site. While true the app shell hides all navigation
  // and configuration affordances (drawer, tab strip, app-bar actions, context
  // menus). Re-derived on every shortcut launch from the target's kioskMode, so
  // a normal launch (no shortcut) or a shortcut to a non-kiosk site clears it.
  bool _kioskLocked = false;

  @override
  void initState() {
    super.initState();
    debugWebViewModels = _sites.models;
    WebViewModel.siteLookup = _sites.byId;
    WidgetsBinding.instance.addObserver(this);
    AppPref.anyChange.addListener(_onAppPrefChanged);
    AppPref.tabStripInFullscreen.listenable.addListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.addListener(_onTabStripPrefChanged);
    _restoreAppState();
    _shortcuts.refreshPinned();
    _shortcuts.probeAppIntents();
    _network.start();
    _fullscreen.start();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onAppPrefChanged() => _rebuild();

  void _onTabStripPrefChanged() {
    if (!AppPref.tabBarButton.value) _fullscreen.tabBarOverlayVisible = false;
    if (_fullscreen.active) _fullscreen.apply();
  }

  /// Push the per-site settings screen for the site at [index].
  ///
  /// Three call sites want it: the two overflow menus, and the
  /// blocked-navigation interstitial, which has to reach the proxy row of
  /// the site it is covering (LEAK-010).
  Future<void> _openSiteSettings(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    await _siteSettingsGuard.run(() async {
      final model = _sites.models[index];
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SettingsScreen(
            webViewModel: model,
            otherSites: _sites.models
                .where((m) => m.siteId != model.siteId)
                .toList(growable: false),
            routingTargets: _links.outboundCandidates(model)
                .where((m) => m.siteId != model.siteId)
                .toList(growable: false),
            useContainers: _sites.useContainers,
            notificationsBlockedBySite: _background.notificationsBlockedBy(model),
            globalUserScripts: _shell.globalUserScripts,
            onGlobalUserScriptsChanged: (scripts) {
              _shell.globalUserScripts = scripts;
              _shell.saveGlobalUserScripts();
              _resetAllWebViews();
            },
            onScriptsChanged: _resetCurrentSiteWebView,
            onClearCookies: () => _clearSiteData(index),
            onSettingsSaved: _handlePerSiteSettingsSaved,
          ),
        ),
      );
      if (!mounted) return;
      await _commitSites(const SiteSettingsClosed());
    });
  }

  /// [_openSiteSettings] for the site [siteId] names, for call sites that
  /// carry the id rather than the index (the nested webview screen).
  Future<void> _openSiteSettingsById(String? siteId) async {
    if (siteId == null) return;
    final index = _sites.models.indexWhere((m) => m.siteId == siteId);
    if (index == -1) return;
    await _openSiteSettings(index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) surfaceRouteObserver.subscribe(this, route);
  }

  /// An opaque route pushed over this page has popped and the webview is
  /// visible again. While it was covered the platform view was not composited,
  /// so Android detached its SurfaceView and re-attaches it here — blank, and
  /// through none of the other chokepoints: the site did not change
  /// (`setCurrentIndex`), the controller was not recreated
  /// (`onControllerReady`), nothing navigated, and the app never left the
  /// foreground. See PAUSE-024 / BUG-001.
  @override
  void didPopNext() {
    _surface.nudge('route-return');
  }

  @override
  void dispose() {
    _background.dispose();
    _surface.dispose();
    _navStateDebouncer.dispose();
    _network.dispose();
    AppPref.anyChange.removeListener(_onAppPrefChanged);
    AppPref.tabStripInFullscreen.listenable
        .removeListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.removeListener(_onTabStripPrefChanged);
    _fullscreen.dispose();
    surfaceRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // A warm-start SurfaceView re-attach lands here, typically after the
    // resume's one-shot nudge drained (PAUSE-020 / BUG-001).
    _surface.metricsChanged();
  }

  @override
  void didChangeTextScaleFactor() => _lifecycle.textScaleChanged();

  @override
  void didHaveMemoryPressure() {
    // OS is signaling memory pressure. Trim one loaded site per
    // event so the system controls the curve — if pressure persists
    // the callback fires again and we evict the next victim. The
    // active site is hard-protected; sites in the active webspace
    // are soft-keep (evicted only after every other candidate).
    unawaited(_handleMemoryPressure());
  }

  Future<void> _handleMemoryPressure() async {
    // Drop concurrent invocations: if the OS fires repeatedly while
    // we're still applying the previous promotion's transition
    // (clearCache, or saveState+dispose), we'd otherwise pick the
    // same victim twice and re-apply the same transition.
    await _memoryPressureGuard.run(() async {
      // The active site and an in-flight activation's target are never
      // picked (PAUSE-006): disposing the soon-to-be-active webview would
      // silently wipe its state.
      final plan = _activation.residencyPlan(const MemoryPressure());
      if (plan.isEmpty) return;
      if (!await _activation.applyResidency(plan, isStale: () => !mounted)) return;
      if (plan.unloads.isNotEmpty) {
        // The pin in force follows the loaded sites (TOR-014). Left for the
        // next activation, the pin of a site evicted here was cleared at
        // whatever moment that came, often after a long suspension had cost
        // the control socket.
        _network.syncTorExitPin(<int>{?_sites.current, ..._sites.loaded});
      }
      setState(() {});

      // The pressure event itself — not our eviction — can blank the VISIBLE
      // site: iOS may jettison its frontmost WKWebView's content process, and
      // the Android hybrid-composition SurfaceView can drop its buffer under a
      // low-memory GL reclaim. The active site is hard-protected from eviction,
      // so neither the promotion above nor `setCurrentIndex` runs against it —
      // it would otherwise stay blank until the next navigation. Probe + nudge
      // it here, covering both outcomes: a dead renderer (recreate) and a
      // live-but-unpainted surface (nudge). See PAUSE-019.
      final activeIdx = AppLifecycleEngine.activeLoadedIndex(
        currentIndex: _sites.current,
        siteCount: _sites.models.length,
        loadedIndices: _sites.loaded,
      );
      if (activeIdx != null) {
        await _lifecycle.probeRenderer(_sites.models[activeIdx],
            trigger: 'memory-pressure');
        if (!mounted) return;
        _surface.nudge('memory-pressure');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mask any visible archive content the moment focus leaves the app
    // (well before `paused`) so the OS snapshot for the task switcher
    // / recents preview never captures an archive-tier site. False
    // positives (popup dialog, app-switcher peek) cost a brief visual
    // overlay flash, not data — acceptable trade for the snapshot
    // guarantee. Armed only while an archive is open (ARCH-009).
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_archives.anyOpen && !_maskBackground) {
        setState(() => _maskBackground = true);
      }
    }
    if (state == AppLifecycleState.resumed && _maskBackground) {
      setState(() => _maskBackground = false);
    }
    _lifecycle.changed(state);
  }

  /// User asked for a repaint from the menu (PAUSE-028).
  ///
  /// Every other repaint trigger is a code path the app recognised as a
  /// surface (re)attach; BUG-001 recurs precisely when a path nobody
  /// enumerated reaches a blank surface, and the user is the only one who can
  /// see that it happened. Probe first so a dead renderer is rebuilt rather
  /// than nudged (the two blank classes look alike), then try the next
  /// mechanism. Android-only.
  void _repaintCurrentSurface() {
    final shown = _sites.shown;
    if (shown != null) {
      unawaited(_lifecycle.probeRenderer(shown, trigger: 'manual'));
    }
    final mechanism = _surface.nextManual();
    switch (mechanism) {
      case ManualRepaint.inset1 || ManualRepaint.inset16:
        _surface.nudge('manual');
      case ManualRepaint.unpaint:
        unawaited(_surface.holdUnpainted());
      case ManualRepaint.nativeInvalidate || ManualRepaint.nativeVisibility:
        unawaited(SurfaceDiagNative.nativeRepaint(
                mechanism.label.substring('native-'.length))
            .then((views) => LogTag.surfaceDiag.debug(
                'manual ${mechanism.label} reached ${views ?? 0} view(s)')));
      case ManualRepaint.recreate:
        _resetCurrentSiteWebView();
    }
  }

  /// LIR-011: open as a nested webview using the chosen site's settings.
  /// LIR-015: a routed outbound link opens the same way over [source], the
  /// site it came from. The ordering lives in [NestedOpenEngine].
  Future<void> _executeOpenNested(
    DispatchOpenNested a, {
    WebViewModel? source,
  }) async {
    final index =
        _sites.models.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) return;
    await NestedOpenEngine.run<WebViewModel>(
      _NestedOpenHost(this, fromTab: a.sourceIsParent && source != null),
      target: _sites.models[index],
      url: a.url,
      source: a.sourceIsParent ? source : null,
    );
  }

  /// The one place a nested screen opens for an existing site from this
  /// widget. Resolves the posture the way `WebViewModel.getWebView`'s own
  /// launches do, so a share, deep link or URL-bar submission carries the same
  /// per-site posture as a tapped link (NESTED-010).
  ///
  /// [opensFromTab] is false for a screen a share opened, which came from no
  /// tab and so has none to hand a link to (LIR-032).
  Future<void> _launchNestedForModel(
    WebViewModel model, {
    required String url,
    bool opensFromTab = true,
  }) =>
      launchUrl(
        url,
        posture: model.sitePosture(globalUserScripts: _shell.globalUserScripts),
        opensFromTab: opensFromTab,
        homeTitle: model.name,
      );

  /// TAB-018: give every app-tier site without a container colour the least
  /// used one. Only app-tier sites count, so what the app-tier list stores
  /// never depends on an archive being open (ARCH-001).
  void _assignContainerColors() {
    final sites = [
      for (final m in _sites.models)
        if (!m.isArchiveTier) m,
    ];
    if (sites.every((m) => m.containerColor != null)) return;
    final given = ContainerColorEngine.assign(
      [for (final m in sites) m.containerColor],
      paletteSize: kContainerPaletteSize,
    );
    for (var i = 0; i < sites.length; i++) {
      sites[i].containerColor = given[i];
    }
  }

  /// The one way the set of sites changes, and what runs after any change to
  /// a site. The order is fixed; [SiteSetChange.effects] decides which steps
  /// run, never in what order.
  Future<void> _commitSites(SiteSetChange change) async {
    // Before anything moves. LIR-023: a deleted site's hosted tabs close
    // before its container goes. ARCH-010: open archives seal before an
    // import replaces the rows they were materialised into.
    switch (change) {
      case SiteRemoved(:final site):
        await _retireSite(site);
        if (!mounted) return;
      case SitesReplaced():
        await _archives.closeAll();
        if (!mounted) return;
      case SitesEdited() ||
            SiteSettingsSaved() ||
            SiteSettingsClosed() ||
            SitesLoaded() ||
            SiteAdded() ||
            SitesMoved() ||
            ArchiveOpened() ||
            ArchiveClosed() ||
            SiteArchived() ||
            SiteUnarchived():
        break;
    }
    final shownBefore = _sites.shown;
    final selectionBefore = _sites.selectedWebspaceId;
    _sites.apply(change);
    _rebuild();
    final effects = change.effects;
    // TAB-018: a site added since the last commit is drawn and written with
    // its colour.
    _assignContainerColors();
    if (effects.prunesReferences) {
      _links.pruneOutboundPreferences();
      _links.pruneSearchReferences();
    }
    if (effects.followsOpeners) {
      await _tabs.reconcileLinkTabs();
      if (!mounted) return;
    }
    if (effects.closesIneligibleTabs) {
      await _tabs.closeIneligibleHostedTabs();
      if (!mounted) return;
    }
    if (change case SiteArchived(:final site, :final into)) {
      await _archives.recordIn(site, into: into);
      if (!mounted) return;
    }
    if (shownBefore != null && !_sites.models.contains(shownBefore)) {
      await _activation.setCurrentIndex(null);
      if (!mounted) return;
    }
    if (_sites.selectedWebspaceId != selectionBefore) {
      unawaited(_shell.saveSelectedWebspaceId());
    }
    // Before the demo-mode bail in the writes: the refcount tracks runtime
    // intent, not persistence, and a demo session that pinned Tor up would
    // keep it up.
    await _network.syncTorHolders();
    unawaited(_network.refreshRoutes());
    if (effects.persists) await _persistSites();
    if (effects.savesWebspaces) await _shell.saveWebspaces();
    if (effects.reschedulesBackground) {
      unawaited(_background.reschedule());
      unawaited(_background.updateAudioSession());
    }
    if (effects.sweepsOrphans) await _sweep.afterRemoval();
  }

  Future<void> _persistSites() async {
    if (isDemoMode) return;
    await _siteStore.save(_sites.models);
    _shortcuts.syncSites();
    // Compile the per-site filter-list mask into the engine. Fire-and-forget:
    // it no-ops unless the mask actually moved, and a save must not wait on
    // an engine reparse.
    unawaited(ContentBlockerService.instance.setListMasks(_filterListMasks()));
  }

  /// Which sites switched each filter list off, by list id, keyed by the
  /// site's registrable host — the identity adblock-rust's `$domain=` scoping
  /// matches against. Archive-tier sites are excluded (ARCH-006): their mask
  /// would rewrite the shared engine cache blob, which must not vary with
  /// whether an archive is open.
  Map<String, Set<String>> _filterListMasks() {
    final masks = <String, Set<String>>{};
    for (final model in _sites.models) {
      final off = model.effectiveDisabledFilterLists;
      if (off.isEmpty) continue;
      final host = getNormalizedDomain(model.initUrl);
      if (host.isEmpty) continue;
      for (final id in off) {
        (masks[id] ??= <String>{}).add(host);
      }
    }
    return masks;
  }

  /// Corner for the currently active site: its remembered per-site choice,
  /// falling back to the app-wide legacy bottom-corner default.
  TabBarCorner get _tabBarButtonCornerEffective {
    final index = _sites.current;
    TabBarCorner? corner;
    if (index != null && index < _sites.models.length) {
      corner = _sites.models[index].tabBarButtonCorner;
    }
    return corner ??
        (AppPref.tabBarButtonOnRight.value
            ? TabBarCorner.bottomRight
            : TabBarCorner.bottomLeft);
  }

  void _openLinkHandlingSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => LinkHandlingSettingsScreen(
          sites: List<WebViewModel>.from(_sites.models),
          onOpenSiteEditor: (site) {
            final idx = _sites.models.indexOf(site);
            if (idx >= 0) {
              Navigator.of(ctx).pop();
              unawaited(_editing.editSite(idx));
            }
          },
          onManualDispatch: (uri) async {
            await _links.dispatchInbound(InboundUrl(uri));
          },
        ),
      ),
    );
  }

  /// Drop the cached HTML snapshot for a site so the next webview rebuild
  /// boots clean — but only when we're (likely) online. When offline the
  /// cached snapshot is the only content we can render, so preserve it
  /// until a live reload can overwrite it (via the `onHtmlLoaded` callback
  /// on the next successful `onLoadStop`).
  ///
  /// Synchronous in-memory eviction. Sync because callers like `_goHome`
  /// dispose the webview and trigger a rebuild in the same event-loop turn
  /// — `getHtmlSync(siteId)` runs during that rebuild's build phase, so an
  /// async eviction loses the race and the rebuilt webview boots with the
  /// stale snapshot anyway. The eviction also bumps the
  /// [HtmlCacheService] generation, so any `saveHtml` for the same siteId
  /// already in flight (e.g. the previous snapshot IPC
  /// resolving after dispose) is rejected at write time and cannot
  /// resurrect the stale bytes the call site just dropped.
  ///
  /// Online gate uses [ConnectivityService.lastKnownOnline] (primed at
  /// startup, refreshed by every probe). Treats unknown as online so
  /// post-startup callers get the eviction; the only cost of a wrong
  /// guess offline is losing the cached fallback for one rebuild —
  /// `controller.reload()` is itself online-gated in [WebViewFactory], so
  /// nothing tries to fetch a live page we can't reach.
  ///
  /// Disk file is left alone. The next live `saveHtml` overwrites it; if
  /// the app is killed before that fires, `preloadCache` reads it back at
  /// next launch and the cached-then-live rebuild path heals it on first
  /// webview load. Use [HtmlCacheService.deleteCache] when the disk file
  /// must also go (orphan cleanup, explicit site deletion).
  void _evictCacheIfOnline(String siteId) {
    if (ConnectivityService.instance.lastKnownOnline ?? true) {
      HtmlCacheService.instance.evictInMemory(siteId);
    }
  }

  /// Dispose the current site's webview so the next render recreates it
  /// with fresh [initialUserScripts] and [initialSettings]. Used after
  /// the user edits the script list or any per-site setting baked at
  /// webview creation time — UA, language, location/timezone, content
  /// blocker, etc. The native WKUserScript / Android UserScript objects
  /// are immutable post-creation, and so are the platform UA / desktop-
  /// mode flags; `controller.loadUrl` alone reloads the *page* but
  /// reuses those baked-in values, so e.g. a desktop UA set after the
  /// webview was created wouldn't activate the desktop_mode_shim.
  ///
  /// Also drops the cached HTML (online only): the snapshot was captured
  /// with the previous script set applied, so showing it on next load
  /// would render the pre-edit DOM before the new scripts re-run.
  void _resetCurrentSiteWebView() {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    _evictCacheIfOnline(_sites.models[_sites.current!].siteId);
    setState(() {
      _sites.models[_sites.current!].disposeWebView();
    });
  }

  /// Persist settings, then recreate the current site's webview so the
  /// updated UA / language / location / shim-relevant fields take effect
  /// through fresh `initialSettings` and `initialUserScripts`. Wired into
  /// [SettingsScreen]'s `onSettingsSaved`.
  Future<void> _handlePerSiteSettingsSaved() async {
    await _commitSites(const SiteSettingsSaved());
    if (!mounted) return;
    final model = _sites.shown;
    if (model != null && model.fullscreenMode) {
      _fullscreen.enter();
    } else {
      _fullscreen.exit();
    }
    if (model != null) {
      _resetCurrentSiteWebView();
    } else {
      setState(() {});
    }
  }

  /// Dispose every loaded webview. Used after global user script edits,
  /// which can affect any site that has opted in. Caches for sites that
  /// have any global opt-in are dropped (online only) for the same reason
  /// as [_resetCurrentSiteWebView].
  void _resetAllWebViews() {
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isNotEmpty) {
        _evictCacheIfOnline(model.siteId);
      }
    }
    setState(() {
      for (final model in _sites.models) {
        model.disposeWebView();
      }
    });
  }

  Future<void> _restoreAppState() async {
    final activationVersionAtRestore = _sites.activationVersion;
    final swRestore = kDebugMode ? (Stopwatch()..start()) : null;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    setState(() {
      _shell.loadTheme(prefs);
      _shortcuts.load(prefs);
      widget.onThemeSettingsChanged(_shell.theme);
    });
    await _shell.loadWebspaces();
    _rebuild();
    await _shell.loadGlobalUserScripts();
    // Before the sites are committed: whether hosted tabs can exist at all
    // depends on the engine (LIR-019), and the commit settles them. Every
    // path downstream branches on it synchronously. False on Android System
    // WebView without MULTI_PROFILE, iOS <17, macOS <14 and unsupported
    // platforms.
    _sites.useContainers = await ContainerNative.instance.isSupported();
    _containerCookieManager =
        _sites.useContainers ? ContainerCookieManager() : null;
    LogTag.container.debug(_sites.useContainers
        ? 'Container API supported — using ContainerIsolationEngine + ContainerCookieManager'
        : 'Container API not supported — using CookieIsolationEngine + (legacy) CookieManager');
    final (sites: restored, :needsResave) =
        await _siteStore.load(onChange: () => setState(() {}));
    if (swRestore != null) {
      LogTag.startup.debug(
          'load ${restored.length} site(s) + cookies: ${swRestore.elapsedMilliseconds}ms');
    }
    // Legacy positional membership resolves against the restored order,
    // before the commit rebuilds every webspace's positions from siteIds.
    if (promoteLegacySiteIndices(_sites.webspaces, sites: restored)) {
      await _shell.saveWebspaces();
    }
    // Sites restored with ProxyType.TOR need the runtime coming up before
    // their first navigation, or each opens on the bootstrap interstitial;
    // the commit's Tor sync does that.
    await _commitSites(SitesLoaded(restored));
    if (await _shell.migrateGlobalScriptOptIn()) {
      await _commitSites(const SitesEdited());
    }
    _shell.suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

    await _network.activateRouter();

    // Startup GC. The container sweeps run here (before any WebView binds —
    // `deleteContainer` is only reliable in that unbound window). The
    // secure-storage / HTML / cookie-jar sweeps are pure housekeeping for
    // sites deleted in previous sessions, so they're deferred until after the
    // launched site has painted (see `_runDeferredStartupGc` below): the
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
    await _containerIsolation.garbageCollectOrphans(activeSiteIdsAtStartup);
    // Drop incognito containers before any WebView binds — `deleteContainer`
    // is reliable in this unbound window on every platform, and we want
    // the container directory gone (next bind materializes a fresh one)
    // so disk usage doesn't grow across sessions.
    final incognitoSiteIds =
        activeSiteIdsAtStartup.difference(nonIncognitoSiteIds);
    for (final siteId in incognitoSiteIds) {
      await _containerIsolation.onSiteDeleted(siteId);
    }
    // Left uninitialised in demo mode, which keeps the store memory-only
    // there.
    if (!isDemoMode) {
      unawaited(SiteIconStore.instance.initialize());
    }

    // Every launch starts on the webspace list unless a shortcut names a site.
    final indexToRestore = await _shortcuts.resolveColdLaunch();
    if (!mounted) return;

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
          await _deferred.queueNavStateRestore(_sites.models[i].siteId);
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
    final preThemeIndices = <int>{
      ..._sites.loaded,
      ?indexToRestore,
    };
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
          final tz = TimezoneLocationService.instance
              .lookup(m.spoofLatitude!, longitude: m.spoofLongitude!);
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
          'activate target site (setCurrentIndex): ${swActivate.elapsedMilliseconds}ms');
    }
    if (!mounted) return;
    // indexToRestore is non-null only for a shortcut cold launch, so apply
    // the FS-008 shortcut-launch fullscreen policy here.
    // KIOSK-003: a locked kiosk launch always goes fullscreen, overriding the
    // per-site / fullscreenOnShortcut policy.
    if (indexToRestore != null &&
        (_kioskLocked ||
            StartupRestoreEngine.shouldEnterFullscreen(
              viaShortcut: true,
              fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
              perSiteFullscreenMode:
                  _sites.models[indexToRestore].fullscreenMode,
            ))) {
      _fullscreen.enter();
    }
    setState(() {});
    if (swRestore != null) {
      LogTag.startup.debug(
          'restore to first setState (total): ${swRestore.elapsedMilliseconds}ms');
    }

    // Container mode: auto-load notification sites now that the launched site
    // has painted — off the first-frame path. Each one's cached/imported HTML
    // is decrypted before it enters _sites.loaded so its build's getHtmlSync
    // hits; doing it here keeps a large notif import from blocking the shortcut
    // target's first paint. (Legacy mode already loaded them pre-paint above.)
    if (_sites.useContainers && !launchedForBackgroundWake) {
      unawaited(DeferredStartupEngine.autoLoadNotificationSites(_deferred)
          .then((_) => _background.reschedule()));
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
    unawaited(DeferredStartupEngine.runPostPaintMaintenance(
      _deferred,
      alreadyThemedSiteIds: preThemeSiteIds,
      needsResave: needsResave,
    ));

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
    unawaited(DeferredStartupEngine.refreshLocationTimezones(_deferred));

    await _background.install();
    // Cold-start path for share intents; the resume handles the warm one.
    unawaited(_links.handleShareIntent());
  }

  late final DialogWebViewPrompts _prompts = DialogWebViewPrompts(context);

  /// What this page answers for every site webview, root and nested.
  late final WebViewHostHooks _webViewHooks = WebViewHostHooks(
    cookieManager: _cookieManager,
    containerCookieManager: _containerCookieManager,
    globalUserScripts: () => _shell.globalUserScripts,
    save: () => _commitSites(const SitesEdited()),
    rebuild: () {
      if (mounted) setState(() {});
    },
    onScreen: (slot) =>
        _sites.current != null &&
        _sites.current! < _sites.models.length &&
        identical(_sites.models[_sites.current!], slot),
    launchNested: launchUrl,
    openInBrowser: launchUrlInSystemBrowser,
    routeOutbound: _links.routeOutbound,
    // Identity, not index: the list can have been reordered by the time the
    // native event lands.
    linkMenu: (source, {required url}) {
      final at = _sites.models.indexOf(source);
      if (at >= 0) unawaited(_showLinkLongPressMenu(at, url: url));
    },
    openSiteSettings: _openSiteSettingsById,
    showPopup: _prompts.showPopup,
    externalScheme: (info, {required loadIn}) async {
      if (!mounted) return;
      await confirmAndLaunchExternalUrl(context,
          info: info, loadInWebView: loadIn);
    },
    confirmScriptFetch: _prompts.confirmScriptFetch,
    untrustedCertificate: _prompts.untrustedCertificate,
    httpAuth: _prompts.httpAuth,
    media: _prompts,
  );

  Future<void> launchUrl(
    String url, {
    required SitePosture posture,
    bool opensFromTab = true,
    String? homeTitle,
  }) async {
    // LIR-032: the screen opens over the tab on screen, and a link in it into
    // one of the user's sites goes back there as a tab. The tab opens once the
    // screen is gone, before whatever its opener runs on close.
    final owner = opensFromTab &&
            _sites.current != null &&
            _sites.current! < _sites.models.length
        ? _sites.models[_sites.current!]
        : null;
    final parentTabId = owner?.activeTabId;
    final openedFrom = owner?.runningIdentity.getDisplayName();
    final nestedSite = _sites.byId(posture.siteId);
    Future<void> Function()? handOff;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(
          url: url,
          openedFrom: openedFrom,
          onOpenAsTab: owner == null || nestedSite == null
              ? null
              : (link, {required hadGesture}) {
                  final tab = _links.tabRouteFor(owner,
                      source: nestedSite, url: link, hadGesture: hadGesture);
                  if (tab == null) return false;
                  handOff = () => _links.executeTabRoute(owner,
                      source: nestedSite,
                      parentTabId: parentTabId,
                      action: tab,
                      url: Uri.parse(link));
                  return true;
                },
          homeTitle: homeTitle,
          posture: posture,
          hooks: _webViewHooks,
          showUrlBar: AppPref.showUrlBar.value,
          onShowUrlBarChanged: ({required show}) => AppPref.showUrlBar.set(show),
        ),
      ),
    );
    final run = handOff;
    if (run != null && mounted) await run();
  }

  /// Shows a SnackBar. Built after the mounted check, so a caller past an
  /// await never reads a defunct context.
  void _toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
    SnackBarAction Function(AppLocalizations loc)? action,
  }) {
    if (!mounted) return;
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message(loc)),
      duration: duration,
      behavior: floating ? SnackBarBehavior.floating : null,
      action: action?.call(loc),
    ));
  }

  void _toastOpenedInNewTab(WebViewModel model, {required String tabId}) =>
      _toast(
        (loc) => loc.tabsOpenedInNewTab,
        action: (loc) => SnackBarAction(
          label: loc.tabsSwitchAction,
          // Sites may have moved or gone by the time this is tapped.
          onPressed: () {
            final at = _sites.models.indexOf(model);
            if (at >= 0) unawaited(_tabs.openTab(at, tabId: tabId));
          },
        ),
      );

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  WebViewController? getController() {
    if(_sites.current == null) {
      return null;
    }
    final model = _sites.models[_sites.current!];
    return model.getController(_webViewHooks);
  }

  void _openDrawerFromBackGesture(ScaffoldState? scaffoldState) {
    if (scaffoldState == null) return;
    _drawerOpenedByBackGesture = true;
    scaffoldState.openDrawer();
  }

  /// Resolve one back gesture: the Android system back button, or a pushable
  /// route's pop.
  Future<void> _handleBackGesture() async {
    await _backGuard.run(() async {
      final scaffoldState = _scaffoldKey.currentState;
      final drawerOpen = scaffoldState?.isDrawerOpen ?? false;
      final controller = getController();
      // Android's canGoBack() is reliable (including for pushState/SPA
      // entries on Chromium). Trust it directly: URL-comparison can
      // false-positive when goBack() succeeds but the navigation
      // hasn't propagated within the timeout. iOS/macOS decide from the
      // URL diff instead, so they don't sample it at all.
      final canGoBack = !drawerOpen && controller != null && hostIsAndroid
          ? await controller.canGoBack()
          : false;
      if (!mounted) return;
      final action = decideBackGesture(
        drawerOpen: drawerOpen,
        drawerOpenedByGesture: _drawerOpenedByBackGesture,
        drawerAvailable: !_kioskLocked,
        hasWebView: controller != null,
        trustsCanGoBack: hostIsAndroid,
        canGoBack: canGoBack,
        atHistoryStart: _backAtHistoryStart,
        canExitApp: hostIsAndroid,
      );
      // At the start of the page history the gesture is still spendable: a
      // tab the user opened from another tab closes and hands back to it
      // (TAB-007). Only then does NAV-001 / NAV-009 get the gesture.
      if ((action == BackGestureAction.ignore ||
              action == BackGestureAction.openDrawer) &&
          controller != null &&
          !drawerOpen) {
        if (await _tabs.backAtTabStart()) return;
        if (!mounted) return;
      }
      switch (action) {
        case BackGestureAction.ignore:
          LogTag.navigation.debug('Back gesture: nothing to do, ignoring');
          break;
        case BackGestureAction.closeDrawer:
          LogTag.navigation.debug('Back gesture: closing open drawer');
          _scaffoldKey.currentState?.closeDrawer();
          break;
        case BackGestureAction.closeDrawerAndExit:
          LogTag.navigation.debug(
              'Back gesture: closing drawer and leaving app');
          _scaffoldKey.currentState?.closeDrawer();
          await SystemNavigator.pop();
          break;
        case BackGestureAction.openDrawer:
          LogTag.navigation.debug('Back gesture: no history, opening drawer');
          _openDrawerFromBackGesture(scaffoldState);
          break;
        case BackGestureAction.exitApp:
          LogTag.navigation.debug('Back gesture: no site shown, leaving app');
          await SystemNavigator.pop();
          break;
        case BackGestureAction.goBack:
          await _goBackAndRepaint(controller!);
          LogTag.navigation.debug('Back gesture: navigated back (canGoBack)');
          break;
        case BackGestureAction.attemptGoBack:
          // iOS/macOS: canGoBack() can return false for pushState
          // entries, so attempt goBack() unconditionally and use URL
          // comparison as the authoritative check.
          final urlBefore = (await controller!.getUrl())?.toString();
          await controller.goBack();
          // Give the native webview time to process the navigation
          await Future.delayed(const Duration(milliseconds: 150));
          if (!mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          final urlChanged = urlBefore != urlAfter;
          LogTag.navigation.debug(urlChanged
              ? 'Back gesture: navigated back from $urlBefore to $urlAfter'
              : 'Back gesture: URL unchanged ($urlAfter)', sensitive: true);
          if (!urlChanged) {
            // Same rule as the Android branch above, reached the only way
            // Apple can reach it: the URL did not move, so the tab is at the
            // start of its own history.
            if (await _tabs.backAtTabStart()) return;
            if (!mounted) return;
          }
          final next = decideAfterAttemptedGoBack(
            urlChanged: urlChanged,
            drawerAvailable: !_kioskLocked,
            atHistoryStart: _backAtHistoryStart,
          );
          if (next == BackGestureAction.openDrawer) {
            LogTag.navigation.debug('Back gesture: no history, opening drawer');
            _openDrawerFromBackGesture(_scaffoldKey.currentState);
          }
          break;
      }
    });
  }

  /// Navigate the visible webview back one history entry, then recomposite the
  /// Android surface. A back/forward-cache restore re-attaches a fresh
  /// hybrid-composition SurfaceView that can come back blank-white, and back
  /// navigation passes through neither `setCurrentIndex` nor `onControllerReady`
  /// (the existing nudge chokepoints), so it would otherwise stay uncovered.
  /// No-op off Android.
  Future<void> _goBackAndRepaint(WebViewController controller) async {
    await controller.goBack();
    _surface.nudge('back');
  }

  /// User-driven reload of the current site (Refresh button, Clear-cookies).
  /// Delegates to [WebViewModel.userDrivenReload] which drops the
  /// HtmlCacheService snapshot and the chromium HTTP cache before the
  /// reload, so the user actually gets fresh content instead of being
  /// served the same stale page from disk cache (issue #290).
  Future<void> _refreshCurrentSite() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    await _sites.models[_sites.current!].userDrivenReload();
  }

  /// User-driven full session wipe for a single site.
  ///
  /// Plan is computed by [SiteDataClearEngine.planClear]; this method
  /// is the executor. Container mode calls
  /// `ContainerIsolationEngine.clearForSite` (fork's
  /// `clearContainerData`, designed for live-bound containers) and
  /// disposes the cached widget so the next IndexedStack rebuild
  /// constructs a fresh InAppWebView against the now-empty container.
  /// Legacy mode falls back to in-model cookie deletion + reload (the
  /// most that can be scoped to a single site when localStorage / IDB
  /// / SW are app-global).
  Future<void> _clearSiteData(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    final model = _sites.models[index];
    final plan = SiteDataClearEngine.planClear(useContainers: _sites.useContainers);

    // Reroll the anti-fingerprinting seed so the post-wipe page can't be
    // re-identified via a stable fingerprint (window size, canvas, …) after
    // a data clear (ETP-022). The fresh nonce is baked into the shim when the
    // webview is rebuilt against the cleared container.
    model.rerollFingerprint();

    if (plan.disposeWebView) {
      _evictCacheIfOnline(model.siteId);
    }

    if (plan.clearContainer) {
      await _containerIsolation.clearForSite(model.siteId);
    }

    if (plan.disposeWebView || plan.clearInModelCookies) {
      setState(() {
        if (plan.disposeWebView) {
          model.disposeWebView();
          // LIR-023: a slot running as this site binds the cleared container.
          for (final other in _sites.models) {
            if (other.activeTab.hostSiteId == model.siteId) {
              other.disposeWebView();
            }
          }
        }
        if (plan.clearInModelCookies) {
          model.cookies = const [];
        }
      });
    }

    if (plan.deleteKnownCookies) {
      await model.deleteCookies(_cookieManager,
          containerCookieManager: _containerCookieManager);
    }
    // Restorable residue the container/cookie wipes don't reach, both engines:
    // the saved `controller.saveState()` bytes are replayed on the next
    // activation, so a page that stashed an identifier in its URL via
    // history.pushState would be reloaded at that URL and read itself back —
    // defeating the fingerprint reroll above (ETP-022). The encrypted HTML
    // snapshot is the same story for the page body.
    _navStateDebouncer.cancel(model.siteId);
    await _stateStorage.removeStatesForSite(model.siteId);
    await HtmlCacheService.instance.deleteCache(model.siteId);
    await _commitSites(const SitesEdited());
    if (!mounted) return;
    if (plan.userDrivenReload) {
      await _refreshCurrentSite();
    }
  }

  Future<void> _stopCurrentSiteLoading() async {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    await _sites.models[_sites.current!].userStopLoading();
  }

  /// Reset every "Always open Home" / incognito site that shares a named
  /// webspace with [launchedIndex] back to its `initUrl` and tear down its
  /// live webview so the next paint reloads at home. Called from both the
  /// cold and warm shortcut entrypoints — on cold launch most flagged
  /// sites already had `currentUrl` dropped during `fromJson`, so the
  /// pass is mostly a no-op there; on warm launch it is the only thing
  /// that resets siblings.
  ///
  /// A site with tabs is not sent home in place: it lands on a tab at home,
  /// and the tab it was on stays in its list (TAB-014).
  Future<void> _resetAlwaysOpenHomeOnShortcut(int launchedIndex) async {
    final indices = WebspaceSelectionEngine.indicesToResetOnShortcutLaunch(
      launchedIndex: launchedIndex,
      webspaces: _sites.webspaces,
      flag: (i) {
        if (i < 0 || i >= _sites.models.length) return false;
        final m = _sites.models[i];
        return m.alwaysOpenHome || m.incognito;
      },
    );
    final withTabs = [
      for (final i in indices)
        if (_tabs.enabledAt(i)) _sites.models[i],
    ];
    for (final i in indices) {
      final m = _sites.models[i];
      if (withTabs.contains(m)) continue;
      if (m.currentUrl == m.initUrl && m.webview == null) continue;
      _evictCacheIfOnline(m.siteId);
      await _tabs.bindOwnerRunTab(m);
      if (!mounted) return;
      m.currentUrl = m.initUrl;
      // Keep the active site in _sites.loaded (mirrors
      // _resetAlwaysOpenHomeForAppClose / _goHome) so the IndexedStack still
      // has a child to rebuild at initUrl. Dropping it black-screens a warm
      // shortcut re-tap of the already-current site: _openShortcutIndex skips
      // setCurrentIndex when index == _sites.current, so nothing would re-add
      // it or recreate the disposed webview.
      if (i == _sites.current) {
        m.disposeWebView();
      } else {
        await _activation.unload(i, reason: UnloadReason.homeReset);
        if (!mounted) return;
      }
    }
    for (final m in withTabs) {
      if (!mounted) return;
      await _tabs.landOnHomeTab(m);
    }
  }

  /// Every site with tabs: the current webspace's in the order the drawer
  /// shows them, then the rest, whose trees can hold tabs that run as a site
  /// the webspace shows (TAB-017). A site without tabs is left out, so its
  /// stored ones cannot be opened from another site's list.
  List<TabsSheetSite> _tabsSheetSites() {
    final view = _sites.filteredIndices();
    final shown = view.toSet();
    TabsSheetSite site(int i) => TabsSheetSite(
          index: i,
          model: _sites.models[i],
          isCurrent: i == _sites.current,
          isLoaded: _sites.loaded.contains(i),
          inView: shown.contains(i),
        );
    return [
      for (final i in view)
        if (_tabs.enabledAt(i)) site(i),
      for (var i = 0; i < _sites.models.length; i++)
        if (!shown.contains(i) && _tabs.enabledAt(i)) site(i),
    ];
  }

  /// A sheet opened while the keyboard is up sits behind it, and the
  /// keyboard stays up while the URL bar or an input in the page has focus.
  Future<void> _dismissKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();
    // A page that is stuck must not keep the list from opening.
    await getController()
        ?.evaluateJavascript(
            'document.activeElement && document.activeElement.blur && '
            'document.activeElement.blur();')
        .timeout(const Duration(milliseconds: 300), onTimeout: () {});
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  Future<void> _showTabsSheet() async {
    if (_kioskLocked || !_tabs.enabledAt(_sites.current) || _isShowingTabsSheet) {
      return;
    }
    _isShowingTabsSheet = true;
    try {
      await _dismissKeyboard();
      if (!mounted || !_tabs.enabledAt(_sites.current)) return;
      await _presentTabsSheet();
    } finally {
      _isShowingTabsSheet = false;
    }
  }

  bool _isShowingTabsSheet = false;

  Future<void> _presentTabsSheet() async {
    final sites = _tabsSheetSites();
    final at = sites.indexWhere((s) => s.index == _sites.current);
    if (at < 0) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => TabsSheet(
        sites: sites,
        currentIndex: at,
        onOpenTab: (i, {required tabId}) =>
            unawaited(_tabs.openTab(i, tabId: tabId)),
        onNewTab: (i) => unawaited(_tabs.newTab(i)),
        onWebSearch: () => unawaited(_links.webSearch()),
        onCloseTab: (i, {required tabId}) =>
            unawaited(_tabs.closeTab(i, tabId: tabId)),
        onCloseSubtree: (i, {required tabId}) =>
            unawaited(_tabs.closeTab(i, tabId: tabId, subtree: true)),
        onMoveTab: _tabs.moveTab,
        onMoveSite: _webspaces.canReorderView ? _moveSiteInTabsSheet : null,
        wayBack: _tabs.wayBackFrom(_sites.models[_sites.current!]),
      ),
    );
  }

  /// A site heading dropped on another in the Tabs sheet (TAB-016): the same
  /// reorder the drawer grid and the tab strip make. Returns the sheet's sites
  /// afresh, since reordering "All" renumbers them.
  List<TabsSheetSite>? _moveSiteInTabsSheet(String siteId,
      {required String ontoSiteId}) {
    if (_tabs.busy || !_webspaces.canReorderView) return null;
    final order = _sites.filteredIndices();
    int at(String id) => order.indexWhere((i) =>
        i >= 0 && i < _sites.models.length && _sites.models[i].siteId == id);
    final from = at(siteId);
    final to = at(ontoSiteId);
    if (from < 0 || to < 0 || from == to) return null;
    _webspaces.reorderSite(from, newListIndex: to);
    return _tabsSheetSites();
  }

  /// A long press that landed on a link. In-domain links can become a tab of
  /// this site; anything else keeps today's behaviour, and the sheet says why
  /// rather than silently offering nothing.
  Future<void> _showLinkLongPressMenu(int index, {required String url}) async {
    if (_kioskLocked || !_tabs.enabledAt(index)) return;
    if (index < 0 || index >= _sites.models.length) return;
    if (index != _sites.current) return;
    final model = _sites.models[index];
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final identity = model.runningIdentity;
    final inDomain =
        getNormalizedDomain(url) == getNormalizedDomain(model.navigationHomeUrl);
    // A link into another of the user's sites becomes that site's tab, as a
    // tap would open it (LIR-032).
    final tabRoute = inDomain
        ? null
        : _links.tabRouteFor(model,
            source: identity, url: url, hadGesture: true);
    final tabHost = switch (tabRoute) {
      DispatchOpenInTab(:final siteId) => _sites.byId(siteId),
      _ => null,
    };
    final choice = await showLinkMenu(
      context,
      url: url,
      newTabEnabled: inDomain || tabRoute != null,
      newTabNote: (loc) => inDomain
          ? null
          : tabHost != null
              ? loc.tabsRunsAs(tabHost.getDisplayName())
              : tabRoute == null
                  ? loc.tabsLinkOutsideSite(uri.host)
                  : null,
    );
    switch (choice) {
      case null:
        return;
      case LinkMenuChoice.newTab:
        if (tabRoute is DispatchShowPicker) {
          unawaited(_links.showOutboundPicker(model,
              source: identity, action: tabRoute, url: uri, parked: true));
        } else if (inDomain) {
          // A sibling of the tab on screen: same container, and when that tab
          // follows an opener's switch (LIR-034), so does it.
          final active = model.activeTab;
          unawaited(_tabs.openLinkInNewTab(index, url: url,
              hostSiteId: active.hostSiteId,
              openerSiteId: active.openerSiteId,
              homeUrl: active.homeUrl));
        } else {
          unawaited(_tabs.openLinkInNewTab(index, url: url,
              hostSiteId: tabHost?.siteId,
              openerSiteId: identity.siteId,
              homeUrl: url));
        }
      case LinkMenuChoice.open:
        unawaited(_links.openLinkAsTapped(index, url: url));
      case LinkMenuChoice.copy:
        await Clipboard.setData(ClipboardData(text: url));
    }
  }

  /// Navigate to the site's initial URL and clear navigation history.
  /// Disposes the webview so it's recreated fresh with no back history.
  /// Evicts the in-memory HTML cache snapshot (online only) so the
  /// rebuilt webview boots clean and goes straight to the live home URL
  /// rather than flashing a stale cached frame. Offline: the cache is
  /// preserved — it's the only content we can render without network.
  void _goHome() {
    if (_sites.current == null || _sites.current! >= _sites.models.length) return;
    final model = _sites.models[_sites.current!];
    _evictCacheIfOnline(model.siteId);
    model.currentUrl = model.navigationHomeUrl;
    model.disposeWebView();
    setState(() {});
    // Re-apply fullscreen for sites with auto-fullscreen after webview recreation
    if (model.fullscreenMode) {
      _fullscreen.enter();
    }
    _commitSites(const SitesEdited());
  }

  String _getThemeTooltip(AppLocalizations loc) {
    final modeName = _shell.theme.themeMode == ThemeMode.system
        ? loc.homeThemeModeSystem
        : _shell.theme.themeMode == ThemeMode.light
            ? loc.homeThemeModeLight
            : loc.homeThemeModeDark;
    final colorName = _shell.theme.accentColor == AccentColor.blue
        ? loc.homeThemeColorBlue
        : loc.homeThemeColorGreen;
    return loc.homeThemeTooltip(modeName, colorName);
  }

  /// The one way the theme changes: the app, its saved settings and every
  /// site's webview follow.
  Future<void> _applyThemeSettings(AppThemeSettings next) async {
    setState(() => _shell.theme = next);
    widget.onThemeSettingsChanged(next);
    await _shell.saveTheme();
    if (!mounted) return;
    final webViewTheme = next.themeMode.webViewTheme;
    for (final model in List.of(_sites.models)) {
      await model.setTheme(webViewTheme);
    }
  }

  Future<void> _openAppSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AppSettingsScreen(
          currentSettings: _shell.theme,
          proxyRouterRunsHere: ProxyRouterService.canRunHere(
              useContainers: _sites.useContainers),
          externalTorRunsHere: externalTorRunsHere,
          siteNames: _siteNames(),
          onSettingsChanged: _applyThemeSettings,
          onExportSettings: _backup.export,
          onImportSettings: _backup.import,
          onTrustUboHosts: _backup.trustUboHosts,
          onRestoreArchive: _archives.promptRestore,
          hasOpenArchives: _archives.anyOpen,
          onCloseAllArchives: () async {
            await _archives.closeAll();
            _toast((loc) => loc.homeArchivesClosed);
          },
          onOpenLinkHandlingSettings: _openLinkHandlingSettings,
          webSearchSites: [
            for (final m in _sites.models)
              if (!m.isArchiveTier &&
                  m.searchCapability?.kind == SearchKind.web)
                (
                  siteId: m.siteId,
                  name: m.getDisplayName(),
                  containerColor: _sites.useContainers
                      ? m.containerColor ??
                          ContainerColorEngine.fallback(
                              m.siteId, paletteSize: kContainerPaletteSize)
                      : null,
                ),
          ],
          globalUserScripts: _shell.globalUserScripts,
          onGlobalUserScriptsChanged: (scripts) {
            _shell.globalUserScripts = scripts;
            _shell.saveGlobalUserScripts();
            _resetAllWebViews();
          },
          onOutboundProxyChanged: _resetAllWebViews,
          siteProxies: () => [
            for (final m in _sites.models) m.proxySettings,
          ],
          onSavedProxiesChanged: () {
            _resetAllWebViews();
            unawaited(_network.refreshRoutes());
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openProtectionReport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlockStatsScreen(siteNames: _siteNames()),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  AppBar _buildAppBar() {
    final loc = AppLocalizations.of(context);
    final currentModel =
        _sites.current != null && _sites.current! < _sites.models.length
            ? _sites.models[_sites.current!]
            : null;
    return AppBar(
      bottom: currentModel == null
          ? null
          : PageLoadBar(
              loading: currentModel.isLoading,
              progress: currentModel.loadingProgress,
            ),
      // KIOSK-002: no leading menu button when locked.
      automaticallyImplyLeading: !_kioskLocked,
      title: _sites.current != null && _sites.current! < _sites.models.length
          ? GestureDetector(
              onDoubleTap: _fullscreen.toggle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      _sites.models[_sites.current!].getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            )
          : Text(_selectedWebspaceName ?? loc.homeNoWebspaceSelected),
      // KIOSK-002: no app-bar actions (download, theme, settings) when locked.
      actions: _kioskLocked ? const <Widget>[] : [
        // Tab count for the site on screen. Present whenever a site is shown,
        // even at one tab, because it is also how a new tab is opened.
        if (currentModel != null && _tabs.enabledAt(_sites.current))
          TabCountButton(
            count: currentModel.tabs.length,
            onPressed: () => unawaited(_showTabsSheet()),
          ),
        const DownloadButton(),
        ThemeModeButton(
          mode: _shell.theme.themeMode,
          tooltip: _getThemeTooltip(loc),
          onChanged: (mode) => _applyThemeSettings(
              _shell.theme.copyWith(themeMode: mode)),
        ),
        // Protection report shield, badged with the week's block count.
        // Same visibility rule as the settings gear: the webspaces list is
        // the app's "home", which is where a protection summary belongs.
        if (_sites.current == null || _sites.current! >= _sites.models.length)
          ProtectionShieldButton(onPressed: _openProtectionReport),
        if (_sites.current == null || _sites.current! >= _sites.models.length)
          IconButton(
            icon: Icon(Icons.settings),
            tooltip: loc.homeAppSettingsTooltip,
            onPressed: _openAppSettings,
          ),
        if (_sites.current != null && _sites.current! < _sites.models.length && !AppPref.showTabStrip.value)
          _siteMenu(SiteMenuPlacement.appBar),
      ],
    );
  }

  /// Whether the bottom tab strip should currently occupy the
  /// bottomNavigationBar slot. Out of fullscreen it follows the "Site Tab
  /// Strip" pref. In fullscreen the behavior is an independent choice: always
  /// visible, revealed on demand by the tab-bar button, or hidden.
  bool get _tabStripShown {
    // KIOSK-002: never show the tab strip in a locked session, in or out of
    // fullscreen — no switching away from the kiosk site.
    if (_kioskLocked) return false;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return false;
    }
    if (_sites.filteredIndices().isEmpty) return false;
    if (_fullscreen.active) {
      if (AppPref.tabStripInFullscreen.value) return true;
      return AppPref.tabBarButton.value && _fullscreen.tabBarOverlayVisible;
    }
    return AppPref.showTabStrip.value || (AppPref.tabBarButton.value && _fullscreen.tabBarOverlayVisible);
  }

  /// Whether the floating tab-bar button is currently shown. It reveals the
  /// tab strip (and its overflow menu) on demand, in and out of fullscreen.
  /// Suppressed while the strip is already pinned or revealed — the strip then
  /// carries its own dismiss control.
  bool get _tabBarButtonShown {
    if (!AppPref.tabBarButton.value) return false;
    // KIOSK-002: a locked session must not expose tab switching.
    if (_kioskLocked) return false;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return false;
    }
    if (_sites.filteredIndices().isEmpty) return false;
    if (_fullscreen.tabBarOverlayVisible) return false;
    if (_fullscreen.active) return !AppPref.tabStripInFullscreen.value;
    return !AppPref.showTabStrip.value;
  }

  /// The tab strip in bottomNavigationBar, which stays at the screen bottom
  /// and is hidden while the keyboard is open.
  Widget? _buildTabStrip() {
    if (!_tabStripShown) return null;
    if (MediaQuery.of(context).viewInsets.bottom > 0) return null;
    return SiteTabStrip(
      models: _sites.models,
      order: _sites.filteredIndices(),
      current: _sites.current,
      revealed: _fullscreen.tabBarOverlayVisible,
      onHide: () {
        setState(() {
          _fullscreen.tabBarOverlayVisible = false;
        });
        _surface.nudge('tab-overlay-hide');
      },
      onOpen: (siteIndex) async {
        await _activation.setCurrentIndex(siteIndex);
        if (!mounted) return;
        setState(() {
          _fullscreen.tabBarOverlayVisible = false;
        });
        _shell.saveCurrentIndex();
      },
      onShowTabs: () => unawaited(_showTabsSheet()),
      onReorder: _webspaces.canReorderView
          ? (from, {required to}) => _webspaces.reorderSite(from, newListIndex: to)
          : null,
      showsTabCount: _tabs.enabledFor,
      menu: _siteMenu(SiteMenuPlacement.bottomBar),
    );
  }

  /// Build the URL bar and find toolbar, placed in the body so that
  /// resizeToAvoidBottomInset keeps them above the keyboard.
  Widget? _buildInputBar() {
    if (_fullscreen.active) return null;
    if (_sites.current == null || _sites.current! >= _sites.models.length) {
      return null;
    }

    final model = _sites.models[_sites.current!];
    final hasUrlBar = AppPref.showUrlBar.value;
    final hasFindToolbar = _isFindVisible && getController() != null;
    if (!hasUrlBar && !hasFindToolbar) {
      return null;
    }
    final urlBarSearch = hasUrlBar && !_kioskLocked && _tabs.featureEnabled
        ? _links.urlBarSearchFor(model)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasFindToolbar)
          FindToolbar(
            webViewController: getController(),
            matches: model.findMatches,
            onClose: () {
              _toggleFind();
            },
          ),
        if (hasUrlBar)
          UrlBar(
            currentUrl: model.currentUrl,
            searchSites: urlBarSearch?.sites ?? const [],
            defaultSearchSiteId: urlBarSearch?.defaultId,
            onSearch: urlBarSearch == null
                ? null
                : (query, {required siteId}) =>
                    _links.searchFromUrlBar(model, query: query, siteId: siteId),
            onSiteInfo: () {
              final id = model.runningIdentity;
              showSiteInfoSheet(
                context,
                info: SiteInfo(
                  siteName: id.getDisplayName(),
                  tabOf: identical(id, model) ? null : model.getDisplayName(),
                  pageUrl: model.currentUrl,
                  proxy: PlatformInfo.isProxySupported
                      ? id.proxySettings
                      : null,
                  siteId: id.siteId,
                  containerId: containerIdFor(
                    siteId: id.siteId,
                    archiveContainerId: id.archiveContainerId,
                    incognito: id.effectiveIncognito,
                  ),
                  incognito: id.effectiveIncognito,
                  containerColor: _sites.useContainers
                      ? id.containerColor ??
                          ContainerColorEngine.fallback(
                              id.siteId, paletteSize: kContainerPaletteSize)
                      : null,
                ),
              );
            },
            onUrlSubmitted: (url) => _links.openTypedAddress(model, url: url),
          ),
      ],
    );
  }

  SiteMenuButton _siteMenu(SiteMenuPlacement placement) => SiteMenuButton(
        placement: placement,
        state: () => (
          loading: _sites.shown?.isLoading ?? false,
          tabsOn: _tabs.enabledAt(_sites.current),
          tabsFeature: _tabs.featureEnabled,
          fullscreen: _fullscreen.active,
          offersShortcut: switch (_sites.shown) {
            final shown? => _shortcuts.offersShortcutFor(shown),
            null => false,
          },
        ),
        nav: (
          back: () => unawaited(_goBackIfPossible()),
          home: _goHome,
          share: () {
            if (_sites.shown case final model?) {
              SharePlus.instance
                  .share(ShareParams(uri: Uri.parse(model.currentUrl)));
            }
          },
          reload: () => unawaited(_refreshCurrentSite()),
          stop: () => unawaited(_stopCurrentSiteLoading()),
          duplicateTab: _tabs.enabledAt(_sites.current)
              ? () {
                  final index = _sites.current;
                  if (index != null) unawaited(_tabs.duplicateTab(index));
                }
              : null,
        ),
        onSelected: _onSiteMenuAction,
      );

  Future<void> _goBackIfPossible() async {
    final controller = getController();
    if (controller == null || !await controller.canGoBack()) return;
    await _goBackAndRepaint(controller);
  }

  Future<void> _onSiteMenuAction(SiteMenuAction action) async {
    final index = _sites.current;
    final model = index != null && index < _sites.models.length
        ? _sites.models[index]
        : null;
    switch (action) {
      case SiteMenuAction.newTab:
        if (model != null) await _tabs.newTab(index!);
      case SiteMenuAction.backToWebspaces:
        await _activation.setCurrentIndex(null);
        if (!mounted) return;
        setState(() {});
        await _shell.saveSelectedWebspaceId();
        await _shell.saveCurrentIndex();
      case SiteMenuAction.search:
        _toggleFind();
      case SiteMenuAction.webSearch:
        await _links.webSearch();
      case SiteMenuAction.toggleUrlBar:
        await AppPref.showUrlBar.set(!AppPref.showUrlBar.value);
      case SiteMenuAction.fullscreen:
        _fullscreen.toggle();
      case SiteMenuAction.repaint:
        _repaintCurrentSurface();
      case SiteMenuAction.settings:
        if (model != null) await _openSiteSettings(index!);
      case SiteMenuAction.devTools:
        if (model == null) return;
        unawaited(Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DevToolsScreen(
              host: WebViewModelDevToolsHost(model),
              cookieManager: _cookieManager,
              containerCookieManager: _containerCookieManager,
              onSave: () => _commitSites(const SitesEdited()),
              globalUserScripts: _shell.globalUserScripts,
              onSimulateBackgroundRefresh: _background.wake,
            ),
          ),
        ));
      case SiteMenuAction.addToHome:
        if (model != null) await _shortcuts.addToHome(model);
    }
  }

  Future<void> _showSiteContextMenu(BuildContext context,
      {required int index, required Offset position}) async {
    final filteredIndices = _sites.filteredIndices();
    final listIndex = filteredIndices.indexOf(index);
    final action = await showSiteListMenu(
      context,
      position: position,
      canMoveUp: _webspaces.canReorderView && listIndex > 0,
      canMoveDown: _webspaces.canReorderView &&
          listIndex >= 0 &&
          listIndex < filteredIndices.length - 1,
      archived: index >= 0 &&
          index < _sites.models.length &&
          _sites.models[index].isArchiveTier,
    );
    final site =
        index >= 0 && index < _sites.models.length ? _sites.models[index] : null;
    switch (action) {
      case null:
        return;
      case SiteListAction.moveToArchive:
        if (site != null) await _archives.moveIn(site);
      case SiteListAction.moveOutOfArchive:
        if (site != null) await _archives.moveOut(site);
      case SiteListAction.closeArchive:
        if (site != null) await _archives.closeArchiveOf(site);
      case SiteListAction.edit:
        await _editing.editSite(index);
      case SiteListAction.delete:
        await _editing.deleteSite(index);
      case SiteListAction.moveUp:
        _webspaces.reorderSite(listIndex, newListIndex: listIndex - 1);
      case SiteListAction.moveDown:
        _webspaces.reorderSite(listIndex, newListIndex: listIndex + 1);
    }
  }

  /// What a deleted site leaves outside the list: its webview, the tabs it
  /// hosts, its shortcut, its container or shared-jar cookies, its pages.
  Future<void> _retireSite(WebViewModel site) async {
    final index = _sites.models.indexOf(site);
    if (index < 0) return;
    site.disposeWebView();
    _sites.loaded.remove(index);
    // LIR-023: every tab the site hosts closes before its container is
    // deleted, which iOS and macOS skip while a webview still binds it.
    await _tabs.closeIneligibleHostedTabs(goneSiteId: site.siteId);
    if (!mounted) return;
    // LIR-022: its hosted tabs keep their bytes under their hosts' keys,
    // which the site's own sweep does not reach.
    for (final t in site.tabs) {
      if (t.hostSiteId != null) {
        await _stateStorage.removeState(site.stateKeyForTab(t.id));
      }
    }
    await ShortcutService.removeShortcut(site.siteId);
    if (!mounted) return;
    if (_sites.useContainers) {
      await _containerIsolation.onSiteDeleted(site.siteId);
    } else {
      // The legacy jar is shared: a loaded same-base-domain site's session
      // is captured and restored around clearing the deleted site's cookies,
      // so the site on screen is not logged out.
      await _cookieIsolation.preDeleteCookieCleanup(
        deletedModel: site,
        deletedIndex: _sites.models.indexOf(site),
        models: _sites.models,
        loadedIndices: _sites.loaded,
      );
    }
    await HtmlCacheService.instance.deleteCache(site.siteId);
    await HtmlImportStorage.instance.deleteImport(site.siteId);
  }

  /// The selected webspace's name, or null while none is selected.
  String? get _selectedWebspaceName {
    final id = _sites.selectedWebspaceId;
    if (id == null) return null;
    return _sites.webspaces
        .firstWhere((ws) => ws.id == id, orElse: () => Webspace(name: 'Unknown'))
        .name;
  }

  Future<void> _backToWebspacesFromDrawer() async {
    await _activation.setCurrentIndex(null);
    if (!mounted) return;
    setState(() {});
    await _shell.saveSelectedWebspaceId();
    await _shell.saveCurrentIndex();
    if (!mounted) return;
    _scaffoldKey.currentState?.closeDrawer();
  }

  /// A site tapped in the drawer, once a webspace switch in flight lands.
  Future<void> _openSiteFromDrawer(int index) async {
    // closeDrawer() (not Navigator.pop) is idempotent: a rapid second tap
    // won't pop the underlying page route once the drawer is already closing.
    _scaffoldKey.currentState?.closeDrawer();
    await _webspaces.switchInFlight;
    await _activation.setCurrentIndex(index);
    if (!mounted) return;
    setState(() {});
    await _shell.saveCurrentIndex();
  }

  /// `siteId` -> display name for the sites the protection report may name.
  /// Archive-tier sites are excluded: they never contribute a count
  /// (STATS-005), so naming them there could only ever be noise.
  Map<String, String> _siteNames() => {
        for (final model in _sites.models)
          if (!model.isArchiveTier) model.siteId: model.getDisplayName(),
      };

  /// The page's hooks on a loaded site, set on every build; each reads the
  /// page's state when it fires.
  void _wireSite(WebViewModel site, {required int index}) {
    _surface.watch(site, onScreen: () => index == _sites.current);
    // Keep the on-disk back/forward stack tracking browsing (PAUSE-009):
    // pause and dispose captures go stale for background sites, and a kill
    // from the switcher only delivers `inactive`, which is ignored (#308).
    // By identity: the list may have changed when the debounce fires.
    site.onNavigationCommitted = () {
      _navStateDebouncer.schedule(site.siteId, capture: () {
        if (!mounted || !_sites.models.contains(site)) return;
        unawaited(_activation.captureStateBytes(site));
      });
    };
    site.onReturnToOwner = _tabs.enabledFor(site)
        ? (url) => unawaited(_tabs.returnToOwner(site, url: url))
        : null;
  }

  /// Build the body with the input bar (URL bar / find toolbar) integrated,
  /// so resizeToAvoidBottomInset naturally keeps them above the keyboard.
  /// The tab strip stays in bottomNavigationBar separately.
  Widget _buildBodyWithBottomBar() {
    for (final i in _sites.loaded) {
      if (i < _sites.models.length) _wireSite(_sites.models[i], index: i);
    }
    final inputBar = _buildInputBar();
    final nudgeInset = _surface.bottomInset;
    // Tab strip in bottomNavigationBar handles bottom safe area when visible.
    // Input bar has its own SafeArea. Only apply body safe area when neither
    // is present (e.g. webspace list screen). The tab strip is also rendered
    // (in bottomNavigationBar) when kept in fullscreen or temporarily revealed
    // by the tab-bar button, in which case it owns the bottom safe-area inset.
    final hasTabStrip = _tabStripShown;
    return SafeArea(
      // Out of fullscreen the AppBar absorbs the top inset, so top stays false.
      // In fullscreen there is no AppBar, and the immersive modes do not
      // reliably hide the status/navigation bars on Android 15 (edge-to-edge
      // enforced) — when they remain, edge-to-edge content lands behind them
      // and the site's top/bottom controls become untappable. Inset the body on
      // both edges so it stays clear of any bars that persist, or that the user
      // revealed under `immersive` (FS-011); when they are truly hidden the
      // padding is ~0 and the webview still fills the screen. github #385
      top: _fullscreen.active,
      bottom: !hasTabStrip && inputBar == null,
      // Out of fullscreen, inset around a landscape display cutout so chrome
      // and content avoid the notch. In fullscreen let the webview fill the
      // cutout strip (with shortEdges cutout mode the window already extends
      // there); otherwise SafeArea would re-letterbox the space beside the
      // notch with the app background. github #457
      left: !_fullscreen.active,
      right: !_fullscreen.active,
      // Use Stack + Offstage so the IndexedStack (and its webview States)
      // stay mounted when showing the webspace list. Removing the
      // IndexedStack from the tree destroys webview States, losing
      // navigation history and scroll position.
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Offstage(
                  offstage: _sites.current != null && _sites.current! < _sites.models.length,
                  child: WebspacesListScreen(
                    webspaces: _sites.webspaces,
                    selectedWebspaceId: _sites.selectedWebspaceId,
                    totalSitesCount: _sites.models.length,
                    accentColor: _shell.theme.accentColor,
                    onSelectWebspace: _webspaces.select,
                    onAddWebspace: _webspaces.add,
                    onEditWebspace: _webspaces.edit,
                    onDeleteWebspace: _webspaces.delete,
                    onReorder: _webspaces.reorder,
                  ),
                ),
                if (_sites.loaded.isNotEmpty)
                  Offstage(
                    offstage: _sites.current == null || _sites.current! >= _sites.models.length,
                    // The inset SurfaceRepaintController toggles to make the
                    // hybrid-composition SurfaceView recomposite (BUG-001);
                    // zero in steady state.
                    child: Visibility(
                      visible: !_surface.hidden,
                      maintainState: true,
                      maintainSize: true,
                      maintainAnimation: true,
                      child: SurfaceNudgeScope(
                      bottomInset: nudgeInset,
                      child: Padding(
                      padding: EdgeInsets.only(bottom: nudgeInset),
                      child: SiteWebViewStack(
                        models: _sites.models,
                        loaded: _sites.loaded,
                        current: _sites.current,
                        hooks: _webViewHooks,
                        showStatsBanner: AppPref.showStatsBanner.value,
                      ),
                    ),
                    ),
                    ),
                  ),
                // Full screen has no app bar to host the progress, kiosk-locked
                // too (fullscreen is forced and held there, KIOSK-003).
                if (_sites.shown case final shown?
                    when _fullscreen.active && shown.isLoading)
                  FullscreenLoadBar(progress: shown.loadingProgress),
                // Back keeps its normal behaviour in full screen. KIOSK-003:
                // no exit handle in a locked session.
                if (_fullscreen.active && !_kioskLocked)
                  FullscreenExitHandle(onExit: _fullscreen.exit),
                // Tab-bar button: a small floating control that reveals the
                // tab strip (with its overflow menu) on demand, in and out of
                // fullscreen. Works on its own (no always-on strip needed).
                // Hidden once the strip is showing — its dismiss control then
                // lives inside the bar instead.
                if (_tabBarButtonShown)
                  Positioned.fill(
                    child: TabBarCornerOverlay(
                      corner: _tabBarButtonCornerEffective,
                      onTap: () {
                        setState(() => _fullscreen.tabBarOverlayVisible = true);
                        _surface.nudge('tab-overlay-show');
                      },
                      // Remembered on the site on screen.
                      onCornerChosen: (corner) {
                        final site = _sites.shown;
                        if (site == null) return;
                        setState(() => site.tabBarButtonCorner = corner);
                        unawaited(_commitSites(const SitesEdited()));
                      },
                    ),
                  ),
              ],
            ),
          ),
          // Always wrap in SafeArea to keep the widget tree stable when
          // the keyboard opens/closes (changing tree structure would unmount
          // the UrlBar, losing TextField focus and closing the keyboard).
          // SafeArea naturally adds 0 padding when keyboard is open.
          if (inputBar != null) SafeArea(top: false, child: inputBar),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool webviewIsVisible = _sites.current != null && _sites.current! < _sites.models.length;
    // From build, not from the paths that change the site on screen: the site
    // shown and the window flag then change in the same frame, and a new path
    // that moves _sites.current cannot skip it (SCREENBLOCK-002).
    final shown = _sites.current;
    unawaited(_screenCaptureGuard.apply(blocked: screenCaptureBlocked(
      appWide: AppPref.blockScreenshots.value,
      siteOnScreen: shown != null && shown >= 0 && shown < _sites.models.length
          ? _sites.models[shown].blockScreenshots
          : null,
    )));
    final mainTree =
        _buildMainTree(context, webviewIsVisible: webviewIsVisible);
    if (!_maskBackground) {
      return mainTree;
    }
    // Snapshot-time mask: an opaque surface overlays everything so the
    // task-switcher / recents preview never captures archive content
    // (ARCH-009). Wrapping the existing tree keeps the running webview
    // state intact — only the painted output is replaced.
    return Stack(
      fit: StackFit.expand,
      children: [
        mainTree,
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Icon(
                Icons.lock_outline,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainTree(BuildContext context,
      {required bool webviewIsVisible}) {
    return PopScope(
      // On Android, always intercept back so the gesture only ever navigates
      // webview history (never exits the app). On other platforms, allow pop
      // only when no webview is visible.
      canPop: hostIsAndroid ? false : !webviewIsVisible,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBackGesture();
      },
      child: Scaffold(
      key: _scaffoldKey,
      // Clearing on close covers every way the drawer goes away; a drawer
      // opened by any other affordance therefore starts with the flag down.
      onDrawerChanged: (isOpen) {
        if (!isOpen) _drawerOpenedByBackGesture = false;
      },
      // Disable the drawer edge-swipe whenever a webview is active so the back
      // gesture never opens the drawer. The drawer is reached via the AppBar
      // menu button instead.
      drawerEdgeDragWidth: webviewIsVisible ? 0 : null,
      appBar: _fullscreen.active ? null : _buildAppBar(),
      // KIOSK-002: no drawer when locked — removes the site grid, "back to
      // webspaces", add-site, and the auto app-bar hamburger / edge swipe.
      drawer: _kioskLocked ? null : SiteDrawer(
        accentColor: _shell.theme.accentColor,
        webspaceName: _selectedWebspaceName,
        models: _sites.models,
        order: _sites.filteredIndices(),
        current: _sites.current,
        showsTabCount: _tabs.enabledAt,
        onBackToWebspaces: () => unawaited(_backToWebspacesFromDrawer()),
        onOpen: (index) => unawaited(_openSiteFromDrawer(index)),
        onMenu: _showSiteContextMenu,
        onReorder: _webspaces.canReorderView
            ? (from, {required to}) => _webspaces.reorderSite(from, newListIndex: to)
            : null,
        onAddSite: () => unawaited(_editing.addSite()),
      ),
      body: _buildBodyWithBottomBar(),
      bottomNavigationBar: _buildTabStrip(),
      floatingActionButton:
          !(_sites.current == null || _sites.current! >= _sites.models.length) ? null
          : FloatingActionButton(
              onPressed: () => unawaited(_editing.addSite()),
              child: Icon(Icons.add),
            ),
    ),
    );
  }
}


/// Binds [NestedOpenEngine] to the page state.
class _NestedOpenHost implements NestedOpenHost<WebViewModel> {
  final _WebSpacePageState state;
  const _NestedOpenHost(this.state, {required this.fromTab});

  /// The screen opens over the tab on screen (outbound routing), not for a
  /// share, so a link in it can come back as a tab (LIR-032).
  final bool fromTab;

  @override
  bool get mounted => state.mounted;

  // Android/Linux: the proxy is a process-global override that only the
  // activation path flips. The nested screen is for a site that is not
  // being activated, so the PROXY-008 sequence runs for it here or it would
  // load through whatever the active site left behind, bound to this site's
  // container (LEAK-003).
  //
  // Under router mode the eviction set is computed router-aware below: the
  // rule points at the relay for every site and the nested screen presents
  // this site's own credential, so `setProxySettings` no-ops and evicting
  // siblings would only cold-start what PROXY-013 keeps loaded.
  @override
  bool get proxyIsProcessGlobal => hostIsAndroid || hostIsLinux;

  @override
  int indexOf(WebViewModel site) => state._sites.models.indexOf(site);

  @override
  int? get currentIndex => state._sites.current;

  @override
  Future<void> switchWebspaceFor(WebViewModel target) async {
    final index = state._sites.models.indexOf(target);
    if (index < 0) return;
    await state._webspaces.revealSite(target, index: index);
  }

  @override
  Set<int> mismatchedWith(WebViewModel target) => {
        for (final unload in state
            ._activation.residencyPlan(NestedOpening(state._sites.models.indexOf(target)))
            .unloads)
          state._sites.models.indexOf(unload.site),
      };

  @override
  Future<void> unload(int index) =>
      state._activation.unload(index, reason: UnloadReason.proxyMismatch);

  @override
  Future<void> applyProxyOf(WebViewModel target) => ProxyManager()
      .setProxySettings(target.proxySettings, siteId: target.siteId);

  @override
  void reportProxyFailure(Object error) {
    LogTag.proxy.error(
        'Nested open refused: proxy apply failed: $error', sensitive: true);
    if (!state.mounted) return;
    state._toast((loc) => loc.siteSettingsProxyError('$error'));
  }

  @override
  Future<void> launchNested(WebViewModel target, {required String url}) =>
      state._launchNestedForModel(target, url: url, opensFromTab: fromTab);

  @override
  Future<void> activate(int index) => state._activation.setCurrentIndex(index);
}

class _ResidencyHost implements ResidencyHost {
  const _ResidencyHost(this.state);

  final _WebSpacePageState state;

  @override
  List<WebViewModel> get models => state._sites.models;

  @override
  Set<int> get loadedIndices => state._sites.loaded;

  @override
  CookieIsolationEngine? get sharedJar =>
      state._sites.useContainers ? null : state._cookieIsolation;

  @override
  Future<void> captureNavState(WebViewModel model) =>
      state._activation.captureStateForRestore(model);

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) =>
      state._background.noteUnloaded(model, reason: reason.label);

  @override
  List<WebViewModel> identities({int? except}) =>
      state._sites.slotIdentities(except: except);

  @override
  SiteRetentionPriority priorityOf(int index) =>
      state._sites.retentionPriority(index);

  @override
  ProxyTopology get proxyTopology => state._network.topology;

  @override
  bool get torAvailable => TorService.instance.isAvailable;
}

/// What the page answers for its controllers.
class _PageHost
    implements
        ShortcutHost,
        ArchiveHost,
        SurfaceHost,
        BackgroundSitesHost,
        LifecycleHost,
        TabsHost,
        LinkHost,
        FullscreenHost,
        ActivationHost,
        BackupHost,
        WebspacesHost,
        SiteEditingHost {
  const _PageHost(this._s);

  final _WebSpacePageState _s;

  @override
  bool get mounted => _s.mounted;

  @override
  void rebuild() => _s._rebuild();

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) =>
      _s._toast(message, duration: duration, floating: floating);

  @override
  Future<void> commitSites(SiteSetChange change) => _s._commitSites(change);

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async {
    final jar = _s._containerCookieManager;
    final controller = model.controller;
    if (controller != null && jar != null) {
      final url = Uri.parse(
        model.currentUrl.isNotEmpty ? model.currentUrl : model.initUrl,
      );
      final fresh = await jar.getCookies(
        controller: controller,
        siteId: model.siteId,
        url: url,
      );
      if (fresh.isNotEmpty) return fresh;
    }
    return List<Cookie>.from(model.cookies);
  }

  @override
  bool get kioskLocked => _s._kioskLocked;

  @override
  set kioskLocked(bool locked) => _s._kioskLocked = locked;

  @override
  void popToRoot() =>
      Navigator.of(_s.context).popUntil((route) => route.isFirst);

  @override
  Future<void> activate(int? index) => _s._activation.setCurrentIndex(index);

  @override
  void closeDrawer() => _s._scaffoldKey.currentState?.closeDrawer();

  @override
  void openDrawer() => _s._scaffoldKey.currentState?.openDrawer();

  @override
  void themeChanged() => _s.widget.onThemeSettingsChanged(_s._shell.theme);

  @override
  void syncTorExitPin(Set<int> indices) => _s._network.syncTorExitPin(indices);

  @override
  void forgetTabReturns() => _s._tabs.forgetReturns();

  @override
  void exitFullscreen() => _s._fullscreen.exit();

  @override
  Future<void> refreshRoutes({int? activeIndex}) =>
      _s._network.refreshRoutes(activeIndex: activeIndex);

  @override
  Future<void> probeRenderer(WebViewModel model, {required String trigger}) =>
      _s._lifecycle.probeRenderer(model, trigger: trigger);

  @override
  void backgroundSitesChanged() {
    unawaited(_s._background.reschedule());
    unawaited(_s._background.updateAudioSession());
  }

  @override
  WebViewHostHooks get webViewHooks => _s._webViewHooks;

  @override
  void enterFullscreen() => _s._fullscreen.enter();

  @override
  void reapplyFullscreen() {
    if (_s._fullscreen.active) _s._fullscreen.apply();
  }

  @override
  Future<bool> captureNavState(WebViewModel model) =>
      _s._activation.captureStateBytes(model);

  @override
  Future<void> handleShareIntent() => _s._links.handleShareIntent();

  @override
  Future<void> resetHomeOnLaunch(int index) =>
      _s._resetAlwaysOpenHomeOnShortcut(index);

  @override
  bool tabsEnabledAt(int index) => _s._tabs.enabledAt(index);

  @override
  Future<void> bindOwnerRunTab(WebViewModel model) =>
      _s._tabs.bindOwnerRunTab(model);

  @override
  Future<void> registerSite(WebViewModel model, {bool activate = true}) =>
      _s._editing.registerSite(model, activate: activate);

  @override
  Future<void> addSiteFromQr(Map<String, dynamic> settings) =>
      _s._editing.addSite(deepLinkQrSettings: settings);

  @override
  WebViewController? controllerOf(WebViewModel model) =>
      model.getController(_s._webViewHooks);

  @override
  Future<void> launchNestedFor(WebViewModel model, {required String url,
         bool opensFromTab = true}) =>
      _s._launchNestedForModel(model, url: url, opensFromTab: opensFromTab);

  @override
  Future<void> openNested(DispatchOpenNested action, {WebViewModel? source}) =>
      _s._executeOpenNested(action, source: source);

  @override
  Future<void> unloadSite(int index, {required UnloadReason reason}) =>
      _s._activation.unload(index, reason: reason);

  @override
  Future<void> wipeContainer(String siteId) async {
    await _s._containerIsolation.clearForSite(siteId);
  }

  @override
  ArchiveHandle? archiveOf(WebViewModel model) =>
      _s._archives.archiveOf(model);

  @override
  void cancelPendingCapture(String siteId) =>
      _s._navStateDebouncer.cancel(siteId);

  @override
  void evictCache(String siteId) => _s._evictCacheIfOnline(siteId);

  @override
  Future<void> saveCurrentIndex() => _s._shell.saveCurrentIndex();

  @override
  Future<void> saveSelectedWebspace() => _s._shell.saveSelectedWebspaceId();

  @override
  Future<void> revealSite(WebViewModel model, {required int index}) =>
      _s._webspaces.revealSite(model, index: index);

  @override
  void offerOpenTab(WebViewModel model, {required String tabId}) =>
      _s._toastOpenedInNewTab(model, tabId: tabId);

  @override
  List<DispatchableSite> tabHostsIn(WebViewModel owner,
          {required WebViewModel opener}) =>
      _s._links.tabHostsIn(owner, source: opener);

  @override
  void noteUnloaded(WebViewModel model, {required String why}) =>
      _s._background.noteUnloaded(model, reason: why);
}
