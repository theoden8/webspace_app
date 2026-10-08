import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/controllers/app_lifecycle_controller.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/screens/add_site.dart' show AddSiteScreen, UnifiedFaviconImage, FaviconUrlCache;
import 'package:webspace/settings/site_suggestion.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_detail.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/fullscreen_system_ui.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';
import 'package:webspace/widgets/find_toolbar.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/widgets/site_info_sheet.dart';
import 'package:webspace/widgets/url_bar.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/services/image_cache_service.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/html_source.dart';
import 'package:webspace/services/deferred_startup_engine.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/archive.dart' show ArchiveHandle;
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_activation_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_teardown_engine.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/site_data_clear_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/nav_state_capture_debouncer.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/ubo_backup_import.dart' show UboTrustedSite, hostTrustedBy;
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/nested_open_engine.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/services/suggested_sites_service.dart' as suggested_sites;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webspace/widgets/download_button.dart';
import 'package:webspace/widgets/edit_site_dialog.dart';
import 'package:webspace/widgets/external_url_prompt.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_webview_stack.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/archive_prompts.dart';
import 'package:webspace/widgets/link_prompts.dart';
import 'package:webspace/widgets/page_load_bar.dart';
import 'package:webspace/widgets/protection_shield_button.dart';
import 'package:webspace/widgets/theme_mode_button.dart';
import 'package:webspace/widgets/shortcut_prompts.dart';
import 'package:webspace/widgets/surface_nudge_scope.dart';
import 'package:webspace/widgets/webview_prompts.dart';
import 'package:webspace/widgets/accent_logo.dart';
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
    with WidgetsBindingObserver, RouteAware
    implements DeferredStartupHost {
  final SiteRuntime _sites = SiteRuntime();
  late final ShortcutController _shortcuts = ShortcutController(_sites,
      host: _PageHost(this), prompts: DialogShortcutPrompts(context));
  late final SurfaceRepaintController _surface = SurfaceRepaintController(
    _PageHost(this),
    repaints: hostIsAndroid,
    traceSuffix: '',
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
  late final ArchiveController _archives = ArchiveController(
    _sites,
    host: _PageHost(this),
    prompts: DialogArchivePrompts(context),
    containers: _containerIsolation,
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
  );
  AppThemeSettings _themeSettings = const AppThemeSettings();
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
  bool _isFullscreen = false; // Runtime fullscreen state (hides appBar, tabStrip, system UI)
  Timer? _revealedBarsHideTimer;
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
  // Runtime-only: whether the tab-bar button has revealed the tab strip.
  // Reset on exiting fullscreen and on site switch; never persisted.
  bool _tabBarOverlayVisible = false;

  Completer<void>? _webspaceSwitchCompleter;

  // Drops concurrent `_handleMemoryPressure` invocations. The OS may
  // fire `didHaveMemoryPressure` repeatedly under sustained pressure;
  // the first handler runs to completion, then the next event picks up
  // the new state. Without this, in legacy (non-container) mode the
  // capture-then-dispose await window lets two handlers pick the same
  // victim and double-write its captured cookies to storage.
  final _memoryPressureGuard = ReentryGuard();
  int _selectWebspaceVersion = 0;

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

  List<SiteSuggestion> _suggestedSites = [];

  List<UserScriptConfig> _globalUserScripts = [];

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
    // Only Android's embedder implements the listener; elsewhere registering
    // it throws MissingPluginException.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setSystemUIChangeCallback(_onSystemUiChange);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onAppPrefChanged() => _rebuild();

  void _onTabStripPrefChanged() {
    if (!AppPref.tabBarButton.value) _tabBarOverlayVisible = false;
    if (_isFullscreen) _applyFullscreenSystemUi();
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
            globalUserScripts: _globalUserScripts,
            onGlobalUserScriptsChanged: (scripts) {
              _globalUserScripts = scripts;
              _saveGlobalUserScripts();
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
  /// (`_setCurrentIndex`), the controller was not recreated
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
    _revealedBarsHideTimer?.cancel();
    SystemChrome.setSystemUIChangeCallback(null);
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
      final plan = _residencyPlan(const MemoryPressure());
      if (plan.isEmpty) return;
      if (!await _applyResidency(plan, isStale: () => !mounted)) return;
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
      // so neither the promotion above nor `_setCurrentIndex` runs against it —
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
        posture: model.sitePosture(globalUserScripts: _globalUserScripts),
        opensFromTab: opensFromTab,
        homeTitle: model.name,
      );

  /// WEBSPACE-012 helper: switch the active webspace to "All" if [model]
  /// isn't a member of the current named webspace, with a snackbar.
  Future<void> _maybeSwitchToAllForSite(WebViewModel model,
      {required int index}) async {
    if (_sites.selectedWebspaceId == null ||
        _sites.selectedWebspaceId == kAllWebspaceId) {
      return;
    }
    final ws = _sites.webspaces.firstWhere(
      (w) => w.id == _sites.selectedWebspaceId,
      orElse: () => _sites.webspaces.first,
    );
    if (ws.siteIndices.contains(index)) return;
    setState(() {
      _sites.selectedWebspaceId = kAllWebspaceId;
    });
    await _saveSelectedWebspaceId();
    _toast((loc) => loc.homeSwitchedToAllToOpen(model.getDisplayName()));
  }

  /// Adds [model] to the selected named webspace too, persists, and with
  /// [activate] puts it on screen. Pass false when the app, not the user,
  /// chose to create it: an unattended entry point must not put a stranger's
  /// page on screen.
  Future<void> _registerNewSite(WebViewModel model, {bool activate = true}) async {
    // Before the first build: initialHtml reads currentTheme to pick the dark
    // prelude for cached HTML (file:// imports especially, which never reload
    // to live), and the model defaults to WebViewTheme.light.
    await model.setTheme(_themeSettings.themeMode.webViewTheme);
    await _commitSites(SiteAdded(model));
    if (!activate || !mounted) return;
    await _setCurrentIndex(_sites.models.indexOf(model));
    if (!mounted) return;
    setState(() {});
    await _saveCurrentIndex();
  }

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
      await _setCurrentIndex(null);
      if (!mounted) return;
    }
    if (_sites.selectedWebspaceId != selectionBefore) {
      unawaited(_saveSelectedWebspaceId());
    }
    // Before the demo-mode bail in the writes: the refcount tracks runtime
    // intent, not persistence, and a demo session that pinned Tor up would
    // keep it up.
    await _network.syncTorHolders();
    unawaited(_network.refreshRoutes());
    if (effects.persists) await _persistSites();
    if (effects.savesWebspaces) await _saveWebspaces();
    if (effects.reschedulesBackground) {
      unawaited(_background.reschedule());
      unawaited(_background.updateAudioSession());
    }
    if (effects.sweepsOrphans) await _sweepOrphans();
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

  Future<void> _saveCurrentIndex() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('currentIndex', _sites.current == null ? 10000 : _sites.current!);
  }

  Future<void> _saveThemeSettings() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('themeSettings', _themeSettings.toStorageIndex());
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
              unawaited(_editSite(idx));
            }
          },
          onManualDispatch: (uri) async {
            await _links.dispatchInbound(InboundUrl(uri));
          },
        ),
      ),
    );
  }

  Future<void> _saveGlobalUserScripts() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = _globalUserScripts.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('globalUserScripts', json);
  }

  Future<void> _loadGlobalUserScripts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    final json = prefs.getStringList('globalUserScripts');
    if (json == null) return;
    final loaded = <UserScriptConfig>[];
    for (var i = 0; i < json.length; i++) {
      try {
        loaded.add(UserScriptConfig.fromJson(
          jsonDecode(json[i]) as Map<String, dynamic>,
        ));
      } catch (e) {
        LogTag.boot.warning(
            'Skipped malformed global user script at index $i: $e');
      }
    }
    _globalUserScripts = loaded;
  }

  /// Migrate pre-opt-in data: older builds ran every enabled global script
  /// on every site. After switching to per-site opt-in, sites that haven't
  /// declared [WebViewModel.enabledGlobalScriptIds] would silently lose
  /// their global scripts. For each site with an empty opt-in set, opt it
  /// into all currently-defined globals once. A marker key prevents this
  /// running again after the user starts curating per-site opt-ins.
  Future<void> _migrateGlobalScriptOptIn() async {
    if (_globalUserScripts.isEmpty || _sites.models.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('globalUserScriptsOptInMigrated') == true) return;
    final allIds = _globalUserScripts.map((s) => s.id).toSet();
    for (final model in _sites.models) {
      if (model.enabledGlobalScriptIds.isEmpty) {
        model.enabledGlobalScriptIds = {...allIds};
      }
    }
    await prefs.setBool('globalUserScriptsOptInMigrated', true);
    await _commitSites(const SitesEdited());
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
      _enterFullscreen();
    } else {
      _exitFullscreen();
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

  Set<String> get _archivedSiteIds => {
        for (final m in _sites.models)
          if (m.isArchiveTier) m.siteId,
      };

  Future<void> _saveWebspaces() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Archive-tier collections and archived siteIds live in `_sites.webspaces`
    // for rendering while open but must not enter app-tier persistence
    // (the archive's own encrypted state carries them).
    List<String> webspacesJson = ArchiveMembershipEngine.persistable(
      _sites.webspaces,
      archivedSiteIds: _archivedSiteIds,
    ).map((webspace) => jsonEncode(webspace.toJson())).toList();
    await prefs.setStringList('webspaces', webspacesJson);
  }

  Future<void> _saveSelectedWebspaceId() async {
    if (isDemoMode) return;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_sites.selectedWebspaceId != null) {
      await prefs.setString('selectedWebspaceId', _sites.selectedWebspaceId!);
    } else {
      await prefs.remove('selectedWebspaceId');
    }
  }

  /// Set the current index and mark it as loaded for lazy webview creation.
  /// This ensures only visited webviews are created, not all webviews at once.
  /// Also handles domain conflict detection for per-site cookie isolation.
  Future<void> _setCurrentIndex(int? index) async {
    final version = ++_sites.activationVersion;
    // Another site by any way leaves the Tabs sheet's way back behind
    // (TAB-019); a jump the sheet makes puts its own back once it lands.
    if (index != _sites.current) _tabs.forgetReturns();

    if (index == null || index < 0 || index >= _sites.models.length) {
      final leaving = _sites.current != null &&
              _sites.current! < _sites.models.length &&
              _sites.loaded.contains(_sites.current)
          ? _sites.models[_sites.current!]
          : null;
      // Going home is committed before the teardown below, never after it
      // (NAV-010): every step there is a native round-trip that can throw,
      // be superseded, or never answer at all, and each of those would
      // abandon the whole call with `_sites.current` still on the site the
      // user asked to leave — a "back to webspaces" that silently did
      // nothing. Nothing in the teardown decides where we end up.
      _sites.current = index;
      _exitFullscreen();
      // Opportunistically capture state for the previously-active site so a
      // later cold start (or OS-killed-while-backgrounded scenario) can
      // re-hydrate its back/forward stack and form data on re-activation.
      // The webview stays loaded (pause-only, not disposed) so a
      // near-immediate return to the same site keeps its in-memory tab.
      // Bytes-only capture — `lifecycleState` stays `live` because the
      // webview is not actually disposed.
      if (leaving != null) {
        await _quiesceOutgoingSite(leaving, version: version);
      }
      return;
    }

    final target = _sites.models[index];

    LogTag.cookieIsolation.debug(
        'Switching to site $index: "${target.name}" (siteId: ${target.siteId})',
        sensitive: true);
    LogTag.cookieIsolation.debug(
        'Target domain: ${getBaseDomain(target.initUrl)}', sensitive: true);
    LogTag.cookieIsolation.debug('Currently loaded indices: ${_sites.loaded}');

    // Mark this site as activation-in-flight so concurrent OS memory
    // pressure events can't pick it as a victim before _sites.current
    // is updated below — disposing the webview mid-activation would
    // silently wipe its state from under the user.
    _sites.activating = index;
    try {

    // Whenever the target is about to be built fresh (not already in
    // `_sites.loaded`), fetch any saved navigation state and hand it to
    // the model so the soon-to-be-built controller's onControllerCreated
    // handler can apply restoreState. This covers both in-session
    // re-activation of a `savedForRestore` site AND a cold start, where
    // every site loads from JSON at the default `resident` tier yet the
    // bytes persisted on the previous run (on navigation / backgrounding)
    // still sit on disk — that's the cross-restart back/forward restore.
    //
    // Skipped when the webview is already loaded (rebuild won't recreate
    // the controller, so a queued restore would be stale) and for sites
    // that never persist nav state — incognito (ephemeral) and
    // archive-tier (ARCH-006: state lives only in the slot ciphertext).
    if (!_sites.loaded.contains(index) && target.activeTabPersistsNavState) {
      final bytes = await _stateStorage.loadState(target.activeStateKey);
      if (version != _sites.activationVersion) return;
      if (bytes != null) {
        target.schedulePendingRestoreState(bytes);
        LogTag.webViewState.debug(
            'Queued ${bytes.length} restore bytes for "${target.name}" '
            '(siteId: ${target.siteId})', sensitive: true);
      }
    }
    // The about-to-be-resumed webview is back at the lowest tier; reset
    // regardless of how it got here (savedForRestore dispose, cacheCleared
    // promotion, or a fresh cold-start load).
    if (target.lifecycleState != SiteLifecycleState.resident) {
      target.lifecycleState = SiteLifecycleState.resident;
    }

    // The loaded sites the target pushes out and the residents that drop
    // their cache. Every rule and its order is SiteUnloadEngine.plan's.
    if (!await _applyResidency(_residencyPlan(Activating(index)),
        isStale: () => version != _sites.activationVersion)) {
      return;
    }

    // Repoint the shared-profile route before this site can issue a
    // request, not after: the identity is shared, so until this lands the
    // relay still holds the previous shared-profile site's upstream.
    if (_network.topology case RoutedProxy(:final sharesDefaultSession)
        when index >= 0 &&
            index < _sites.models.length &&
            sharesDefaultSession(_sites.models[index])) {
      await _network.refreshRoutes(activeIndex: index);
      if (version != _sites.activationVersion) return;
    }

    // Only once the disagreeing siblings are gone: SETCONF takes effect for
    // the whole runtime the moment it lands, so applying it first would
    // route their next request through the new country. Not awaited: the
    // target, if it uses Tor, is held behind the interstitial until the pin
    // lands, and a target that does not use Tor has no reason to wait on tor
    // at all.
    if (TorService.instance.isAvailable) {
      _network.syncTorExitPin(<int>{index, ..._sites.loaded});
    }

    // Pause the previously active webview to save resources. Nothing to do
    // when the user tapped the site they are already on — see the engine.
    final outgoing = SiteActivationEngine.outgoingSiteToQuiesce(
      currentIndex: _sites.current,
      targetIndex: index,
      siteCount: _sites.models.length,
      loadedIndices: _sites.loaded,
    );
    if (outgoing != null) {
      await _quiesceOutgoingSite(_sites.models[outgoing], version: version,
          captureState: false);
      if (version != _sites.activationVersion) return;
    }

    if (_sites.useContainers) {
      // Container path: ensure the named container is recorded.
      // Materialization happens lazily on the native side when the
      // WebView binds via `InAppWebViewSettings.containerId`.
      await _containerIsolation.ensureContainer(target.siteId);
      if (version != _sites.activationVersion) return;
    } else {
      await _restoreCookiesForSite(index);
      if (version != _sites.activationVersion) return;
    }

    // Validate index is still in bounds after async gaps
    if (index >= _sites.models.length) return;

    // Decrypt this site's cached/imported HTML into memory before it enters
    // _sites.loaded, so the build's synchronous getHtmlSync hits. Idempotent
    // no-op for sites that have no cached/imported HTML, e.g. a plain URL site.
    await _ensureSiteHtml(index);
    if (version != _sites.activationVersion) return;

    _sites.current = index;
    // Bump to end of insertion order so iteration over _sites.loaded is
    // least-recently-used first (consumed by the LRU eviction above).
    _sites.loaded.remove(index);
    _sites.loaded.add(index);

    await _sites.models[index].resumeWebView();

    // A site that sat offscreen while the OS reclaimed memory can come back
    // with a dead renderer (iOS content-process jettison whose termination
    // delegate never fired) or a blank surface (Android hybrid-composition).
    // Probe and recover so a shortcut tap or tab switch doesn't land on a
    // black/blank page. See PAUSE-013.
    unawaited(_lifecycle.probeRenderer(target, trigger: 'site-switch'));

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
    final loadedSnapshot = _sites.loaded.toList();
    for (final i in loadedSnapshot) {
      if (i == index) continue;
      if (i < 0 || i >= _sites.models.length) continue;
      // Camera stop is dispatched before the pause (CAM-012) and covers the
      // sites pauseWebView() exempts — a notification or background-audio
      // site keeps its JS running, which is exactly where a forgotten capture
      // would survive. Bound to a local model: the steps run a microtask
      // later, by which point _sites.models may have been reindexed.
      final model = _sites.models[i];
      unawaited(
          _quiesceOutgoingSite(model, version: version, captureState: false));
    }

    if (target.fullscreenMode) {
      _enterFullscreen();
    } else {
      _exitFullscreen();
    }

    LogTag.cookieIsolation.debug(
        'After switch, loaded indices: ${_sites.loaded}', sensitive: true);
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
    // schedule. No-op on non-iOS / non-Android.
    unawaited(_background.reschedule());
    // Same trigger for the iOS audio session: the first load of a
    // background-audio site must activate `.playback` before the user
    // starts playback in it.
    unawaited(_background.updateAudioSession());
    } finally {
      // Clear the in-flight marker only if we still own it; a newer
      // _setCurrentIndex caller will have already overwritten it with
      // its own target.
      if (_sites.activating == index) {
        _sites.activating = null;
      }
    }
  }

  /// Unloads the site at [index] (PAUSE-007, ISO-002); see
  /// [SiteUnloadEngine.unload].
  Future<void> _unloadSite(int index, {required UnloadReason reason}) =>
      SiteUnloadEngine.unload(_ResidencyHost(this),
          index: index, reason: reason);

  ResidencyPlan _residencyPlan(ResidencyEvent event) =>
      SiteUnloadEngine.plan(_ResidencyHost(this), event: event);

  /// False when [isStale] turned true partway; see [SiteUnloadEngine.apply].
  Future<bool> _applyResidency(
    ResidencyPlan plan, {
    required bool Function() isStale,
  }) =>
      SiteUnloadEngine.apply(_ResidencyHost(this),
          plan: plan, isStale: isStale);

  /// Every navigation-state key that should survive a sweep, for the sites in
  /// [siteIds]. State is per tab, so a site contributes one key per tab it
  /// still has: closing a tab makes its file an orphan, and deleting a site
  /// makes all of them orphans. The engine that drives the sweep speaks in
  /// sites (it has no reason to know about tabs); expanding a site to its keys
  /// belongs here, where the models are.
  Set<String> _liveStateKeys(Set<String> siteIds) => <String>{
        for (final m in _sites.models)
          if (siteIds.contains(m.siteId))
            for (final t in m.tabs) m.stateKeyForTab(t.id),
      };

  /// Capture [model]'s navigation state to encrypted on-disk storage.
  /// Returns true if bytes were captured and persisted. No-op for
  /// incognito sites or when there's nothing to save.
  ///
  /// Does NOT mutate `model.lifecycleState` — callers that are
  /// disposing the webview should do that themselves (typically
  /// flipping to [SiteLifecycleState.savedForRestore]); callers that
  /// are *only* opportunistically persisting (go-home,
  /// app-background) should leave the state at [SiteLifecycleState.resident]
  /// since the webview is still in memory.
  Future<bool> _captureStateBytes(WebViewModel model) async {
    // Archive-tier (ARCH-006) and incognito sites never persist nav state,
    // and a hosted tab only when its host would keep it (LIR-022).
    if (!model.activeTabPersistsNavState) return false;
    // The key is the one the bytes belong to, read before the capture: a tab
    // switch or a container flip (LIR-034) landing while it runs would make
    // the key read afterwards name another tab or another identity, and these
    // bytes would be restored there.
    final tabId = model.activeTabId;
    final key = model.activeStateKey;
    final bytes = await model.captureNavigationState();
    if (bytes == null) return false;
    if (model.activeTabId != tabId || model.activeStateKey != key) {
      LogTag.webViewState.debug(
          'Dropped a capture for "${model.name}": its tab changed meanwhile',
          sensitive: true);
      return false;
    }
    await _stateStorage.saveState(key, state: bytes);
    LogTag.webViewState.debug(
        'Captured ${bytes.length} bytes for "${model.name}" '
        '(state key: $key)', sensitive: true);
    return true;
  }

  /// Quiesce the site the user is leaving — a site switch, or a return to the
  /// webspace list (which also captures nav state).
  ///
  /// Ordering is CAM-012 / BGAUDIO-009: on iOS the per-instance pause blocks
  /// the page's JS thread, so the camera stop and the media pause have to be
  /// dispatched before it or they sit queued behind it forever. That same
  /// freeze is why the engine bounds the sequence — a page an earlier pause
  /// left frozen never answers `evaluateJavascript` again, and the caller's
  /// own state change must not hang on it (NAV-010).
  Future<void> _quiesceOutgoingSite(
    WebViewModel model, {
    required int version,
    bool captureState = true,
  }) async {
    final result = await SiteTeardownEngine.quiesceOutgoing(
      superseded: () => version != _sites.activationVersion,
      steps: [
        if (captureState)
          SiteTeardownStep('captureState',
              run: () => _captureStateBytes(model)),
        SiteTeardownStep('stopRealCapture', run: model.stopRealCapture),
        SiteTeardownStep('pauseMediaPlayback', run: model.pauseMediaPlayback),
        SiteTeardownStep('pauseWebView', run: model.pauseWebView),
      ],
    );
    if (result.isClean) return;
    LogService.instance.log(
      LogTag.webView,
      message: 'Teardown of "${model.name}" ran ${result.ran}'
          '${result.errors.isEmpty ? '' : ', failed ${result.errors}'}'
          '${result.stalledOn == null ? '' : ', stalled on ${result.stalledOn}'}'
          '${result.supersededBefore == null ? '' : ', superseded before ${result.supersededBefore}'}',
      level: result.stalledOn == null ? LogLevel.info : LogLevel.warning,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Capture state and flip the lifecycle to [SiteLifecycleState.savedForRestore].
  /// Used by dispose paths (LRU eviction, memory-pressure cascade,
  /// legacy webspace-switch unload) where the webview is about to be
  /// torn down.
  Future<void> _captureStateForRestore(WebViewModel model) async {
    final ok = await _captureStateBytes(model);
    if (ok) {
      model.lifecycleState = SiteLifecycleState.savedForRestore;
    }
  }

  /// Restores cookies for a site before activation.
  Future<void> _restoreCookiesForSite(int index) async {
    final version = _sites.activationVersion;
    await _cookieIsolation.restoreCookiesForSite(
      index: index,
      models: _sites.models,
      loadedIndices: _sites.loaded,
      versionAtEntry: version,
      currentVersion: () => _sites.activationVersion,
    );
  }

  Future<void> _loadWebspaces() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? webspacesJson = prefs.getStringList('webspaces');

    if (webspacesJson != null) {
      final loadedWebspaces = <Webspace>[];
      for (var i = 0; i < webspacesJson.length; i++) {
        try {
          loadedWebspaces.add(Webspace.fromJson(jsonDecode(webspacesJson[i])));
        } catch (e) {
          LogTag.boot.warning('Skipped malformed webspace at index $i: $e');
        }
      }

      setState(() {
        _sites.webspaces.addAll(loadedWebspaces);
      });
    }

    _ensureAllWebspaceExists();

    _sites.selectedWebspaceId = prefs.getString('selectedWebspaceId');

    if (_sites.selectedWebspaceId == null) {
      _sites.selectedWebspaceId = kAllWebspaceId;
    }
  }

  void _ensureAllWebspaceExists() {
    final hasAll = _sites.webspaces.any((ws) => ws.id == kAllWebspaceId);

    if (!hasAll) {
      setState(() {
        _sites.webspaces.insert(0, Webspace.all());
      });
    } else {
      // Ensure "All" is at the beginning
      final allIndex = _sites.webspaces.indexWhere((ws) => ws.id == kAllWebspaceId);
      if (allIndex > 0) {
        setState(() {
          final allWebspace = _sites.webspaces.removeAt(allIndex);
          _sites.webspaces.insert(0, allWebspace);
        });
      }
    }
  }

  Future<void> _restoreAppState() async {
    final activationVersionAtRestore = _sites.activationVersion;
    final swRestore = kDebugMode ? (Stopwatch()..start()) : null;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    setState(() {
      // Load theme settings, with migration from old formats
      final savedThemeSettings = readPrefAs<int>(prefs, key: 'themeSettings');
      if (savedThemeSettings != null) {
        _themeSettings = AppThemeSettings.fromStorageIndex(savedThemeSettings);
      } else {
        // Try to migrate from old appTheme format
        final savedAppTheme = readPrefAs<int>(prefs, key: 'appTheme');
        if (savedAppTheme != null && savedAppTheme < AppTheme.values.length) {
          _themeSettings = AppTheme.values[savedAppTheme].settings;
        } else {
          // Migrate from old themeMode if exists
          final oldThemeMode = readPrefAs<int>(prefs, key: 'themeMode');
          if (oldThemeMode != null) {
            // Map old ThemeMode to new settings (assuming green was the old color)
            switch (oldThemeMode) {
              case 0: // ThemeMode.system
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.system, accentColor: AccentColor.green);
                break;
              case 1: // ThemeMode.light
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.light, accentColor: AccentColor.green);
                break;
              case 2: // ThemeMode.dark
                _themeSettings = AppThemeSettings(themeMode: ThemeMode.dark, accentColor: AccentColor.green);
                break;
              default:
                _themeSettings = const AppThemeSettings();
            }
          }
        }
      }
      _shortcuts.load(prefs);
      widget.onThemeSettingsChanged(_themeSettings);
    });
    await _loadWebspaces();
    await _loadGlobalUserScripts();
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
      await _saveWebspaces();
    }
    // Sites restored with ProxyType.TOR need the runtime coming up before
    // their first navigation, or each opens on the bootstrap interstitial;
    // the commit's Tor sync does that.
    await _commitSites(SitesLoaded(restored));
    await _migrateGlobalScriptOptIn();
    _suggestedSites = await suggested_sites.getEffectiveSuggestedSites();

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
    // so `_setCurrentIndex`'s conflict-unload can arbitrate same-base-domain
    // collisions; preload each one's HTML so its first build's getHtmlSync hits.
    if (!_sites.useContainers && !launchedForBackgroundWake) {
      for (int i = 0; i < _sites.models.length; i++) {
        if (_sites.models[i].effectiveNotificationsEnabled) {
          await _ensureSiteHtml(i);
          // PAUSE-019: same pre-queue as the container-mode deferred
          // path — once in _sites.loaded the activation restore is
          // skipped, so the back/forward stack must be queued now.
          await queueNavStateRestore(_sites.models[i].siteId);
          _sites.loaded.add(i);
        }
      }
    }

    // Apply saved theme BEFORE _setCurrentIndex so the first build sees the
    // right currentTheme — initialHtml reads it to pick the dark prelude for
    // cached HTML (file:// imports especially, which never reload to live and
    // so paint with whatever prelude the first build chose). Models default to
    // WebViewTheme.light, so without this the first frame on a dark theme
    // flashes white before the controller is created and re-applies via
    // setController(). Only the models built this frame (launched site + any
    // auto-loaded notification sites) need it now; the rest are themed after
    // paint — their controllers aren't created until activated, and
    // setController re-applies the theme then.
    final webViewTheme = _themeSettings.themeMode.webViewTheme;
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
      await _setCurrentIndex(indexToRestore);
    }
    if (swActivate != null) {
      LogTag.startup.debug(
          'activate target site (_setCurrentIndex): ${swActivate.elapsedMilliseconds}ms');
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
      _enterFullscreen();
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
      unawaited(DeferredStartupEngine.autoLoadNotificationSites(this)
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
      this,
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
    unawaited(DeferredStartupEngine.refreshLocationTimezones(this));

    await _background.install();
    // Cold-start path for share intents; the resume handles the warm one.
    unawaited(_links.handleShareIntent());
  }

  /// Decrypt the cached/imported HTML for one site into memory before its
  /// webview builds, so the build's synchronous `getHtmlSync` hits. Uses the
  /// same [htmlSourceFor] classification as the build's `initialHtml` read, so
  /// the preload can never target a different store than the read (a blank
  /// site). Cheap no-op when the site has nothing on disk.
  Future<void> _ensureSiteHtml(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    await _ensureSiteHtmlForModel(_sites.models[index]);
  }

  /// Model-keyed variant — safe to call across `await`s in deferred loops where
  /// the index may shift (a site added/deleted while it runs), since it doesn't
  /// re-index `_sites.models`.
  Future<void> _ensureSiteHtmlForModel(WebViewModel m) async {
    switch (htmlSourceFor(
      incognito: m.incognito,
      isArchiveTier: m.isArchiveTier,
      initUrl: m.initUrl,
    )) {
      case HtmlSource.import:
        await HtmlImportStorage.instance.preloadOne(m.siteId);
      case HtmlSource.cache:
        await HtmlCacheService.instance.preloadOne(m.siteId);
      case HtmlSource.none:
        break;
    }
  }

  // Drives DeferredStartupEngine for the post-paint deferred init (notif
  // auto-load, timezone re-bake). Everything is addressed by siteId and the
  // siteId<->index translation happens fresh per call, so an add/delete while
  // the deferred work is awaiting can never make it act on a stale position.

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
  bool get isMounted => mounted;

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
    if (m != null) await _ensureSiteHtmlForModel(m);
  }

  @override
  Future<void> applyTheme(String siteId) async {
    final m = _sites.byId(siteId);
    if (m != null) {
      await m.setTheme(_themeSettings.themeMode.webViewTheme);
    }
  }

  /// PAUSE-019: pre-queue the saved back/forward stack for a site that
  /// is about to enter `_sites.loaded` without going through
  /// `_setCurrentIndex` (auto-loaded notification sites). Once it's in
  /// the set, the activation path skips its restore fetch, so a queue
  /// here is the only chance the bytes get applied on this run.
  @override
  Future<void> queueNavStateRestore(String siteId) async {
    final model = _sites.byId(siteId);
    if (model == null) return;
    // A live controller can't consume queued bytes — restoreState only
    // applies to a freshly-created one.
    if (!model.activeTabPersistsNavState || model.controller != null) return;
    final bytes = await _stateStorage.loadState(model.activeStateKey);
    if (bytes == null) return;
    // Re-resolve after the disk read: the site may have been deleted.
    if (_sites.byId(siteId) == null) return;
    model.schedulePendingRestoreState(bytes);
    LogTag.webViewState.debug(
        'Queued ${bytes.length} restore bytes for auto-loaded site '
        '"${model.name}" (siteId: $siteId)', sensitive: true);
  }

  @override
  void requestRebuild() {
    if (mounted) setState(() {});
  }

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
  Future<void> persist() => _commitSites(const SitesEdited());

  @override
  Set<String> liveSiteIds() => {for (final m in _sites.models) m.siteId};

  @override
  Set<String> liveNonIncognitoSiteIds() =>
      {for (final m in _sites.models) if (!m.incognito) m.siteId};

  /// Housekeeping sweep of storage left by sites deleted in previous sessions,
  /// deferred off the cold-launch first-paint path. The launched site never
  /// reads any of this — its cookies come from its hydrated model (legacy) or
  /// its own container — so running it after paint changes nothing the user
  /// sees, only when the disk reclaim happens. The live-set args are read fresh
  /// by the engine at sweep time so a site added post-paint isn't reclaimed.
  @override
  Future<void> sweepOrphanStorage(
    Set<String> activeSiteIds, {
    required Set<String> nonIncognitoSiteIds,
  }) async {
    try {
      await OrphanSweepEngine.sweep(
        targets: _OrphanSweepTargets(this),
        activeSiteIds: activeSiteIds,
        nonIncognitoSiteIds: nonIncognitoSiteIds,
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.launch,
      );
      // Blocklist levels nothing asks for any more: a site that moved back
      // to the app-wide level leaves its tier behind, and each one is a
      // multi-megabyte file plus its share of the in-memory partition. Only
      // here, not on every model save — an unsaved per-site edit is not in
      // `_sites.models` yet, and pruning against it would delete the tier
      // the user just waited for.
      await DnsBlockService.instance.pruneLevels(requiredDnsLevels(
        globalLevel: DnsBlockService.instance.level,
        siteLevels: [for (final m in _sites.models) m.effectiveDnsBlockLevel],
      ));
    } catch (e) {
      LogTag.startup.error('Deferred startup GC failed: $e');
    }
  }

  /// Sweep after sites left the list while the app runs (delete, import).
  Future<void> _sweepOrphans() => OrphanSweepEngine.sweep(
        targets: _OrphanSweepTargets(this),
        activeSiteIds: liveSiteIds(),
        nonIncognitoSiteIds: liveNonIncognitoSiteIds(),
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.sitesRemoved,
      );

  late final DialogWebViewPrompts _prompts = DialogWebViewPrompts(context);

  /// What this page answers for every site webview, root and nested.
  late final WebViewHostHooks _webViewHooks = WebViewHostHooks(
    cookieManager: _cookieManager,
    containerCookieManager: _containerCookieManager,
    globalUserScripts: () => _globalUserScripts,
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

  void _enterFullscreen() {
    if (_isFullscreen) {
      // The mode depends on the kiosk lock and the tab strip prefs, which a
      // shortcut launch or an import can change while already full screen.
      _applyFullscreenSystemUi();
      return;
    }
    setState(() {
      _isFullscreen = true;
    });
    _applyFullscreenSystemUi();
    // Removing the app bar / changing the bottom bar resizes the webview; on
    // Android the hybrid-composition SurfaceView can come back with a 1px dark
    // seam at the bottom edge until it recomposites. github #421-followup
    _surface.nudge('fullscreen-toggle');
    // KIOSK-003: the hint promises an exit that a locked session won't honor.
    if (_kioskLocked) return;
    _toast((loc) => loc.homeExitFullscreenHint,
        duration: const Duration(seconds: 2), floating: true);
  }

  void _exitFullscreen() {
    // KIOSK-003: a locked kiosk session stays fullscreen; the only exit is to
    // relaunch the app normally (which clears the lock).
    if (_kioskLocked) return;
    if (!_isFullscreen) return;
    _revealedBarsHideTimer?.cancel();
    setState(() {
      _isFullscreen = false;
      _tabBarOverlayVisible = false;
    });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _surface.nudge('fullscreen-exit');
  }

  SystemUiMode get _fullscreenSystemUiMode => fullscreenSystemUiMode(
        tabStripInFullscreen: AppPref.tabStripInFullscreen.value,
        tabBarButton: AppPref.tabBarButton.value,
        kioskLocked: _kioskLocked,
      );

  void _applyFullscreenSystemUi() {
    SystemChrome.setEnabledSystemUIMode(_fullscreenSystemUiMode);
  }

  /// Under `immersive` (FS-011) a bar the user swipes in stays until the app
  /// hides it; the body and the tab strip inset around it meanwhile.
  Future<void> _onSystemUiChange(bool systemOverlaysAreVisible) async {
    _revealedBarsHideTimer?.cancel();
    if (!mounted || !_isFullscreen) return;
    if (_fullscreenSystemUiMode != SystemUiMode.immersive) return;
    _surface.nudge('system-bars');
    if (!systemOverlaysAreVisible) return;
    _revealedBarsHideTimer = Timer(kRevealedSystemBarsHideDelay, () {
      if (mounted && _isFullscreen) _applyFullscreenSystemUi();
    });
  }

  void _toggleFullscreen() {
    if (_isFullscreen) {
      _exitFullscreen();
    } else {
      _enterFullscreen();
    }
  }

  void _addWebspace() async {
    final webspace = Webspace(name: '');
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspace,
          allSites: _sites.models,
          onSave: (updatedWebspace) {
            // The editor returns positional siteIndices; translate to
            // siteIds (the persisted source of truth) before storing.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _sites.models.length)
                  _sites.models[i].siteId,
            ];
            setState(() {
              _sites.webspaces.add(updatedWebspace.copyWith(siteIds: selectedSiteIds));
              _sites.resolveWebspaceIndices();
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _editWebspace(Webspace webspace) async {
    // For "All" webspace, show all sites as selected but read-only.
    // The synthetic projection has to populate BOTH siteIds and
    // siteIndices so the editor's "selected" state matches.
    final webspaceToEdit = webspace.id == kAllWebspaceId
        ? Webspace(
            id: kAllWebspaceId,
            name: 'All',
            siteIds: [for (final m in _sites.models) m.siteId],
            siteIndices: List<int>.generate(_sites.models.length, (index) => index),
          )
        : webspace;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebspaceDetailScreen(
          webspace: webspaceToEdit,
          allSites: _sites.models,
          isReadOnly: webspace.id == kAllWebspaceId,
          onSave: (updatedWebspace) {
            if (updatedWebspace.id == kAllWebspaceId) return;

            // Translate the editor's index-based selection back into
            // the siteId-keyed persisted membership.
            final selectedSiteIds = <String>[
              for (final i in updatedWebspace.siteIndices)
                if (i >= 0 && i < _sites.models.length)
                  _sites.models[i].siteId,
            ];
            setState(() {
              final index = _sites.webspaces.indexWhere((ws) => ws.id == updatedWebspace.id);
              if (index != -1) {
                _sites.webspaces[index] = updatedWebspace.copyWith(siteIds: selectedSiteIds);
                _sites.resolveWebspaceIndices();
              }
            });
            _saveWebspaces();
          },
        ),
      ),
    );
  }

  void _deleteWebspace(Webspace webspace) async {
    final loc = AppLocalizations.of(context);
    if (webspace.id == kAllWebspaceId) {
      _toast((loc) => loc.homeCannotDeleteAllWebspace);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeDeleteWebspaceTitle),
        content: Text(loc.homeDeleteWebspaceConfirm(webspace.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonDelete),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final wasSelected = _sites.selectedWebspaceId == webspace.id;
    setState(() {
      _sites.webspaces.removeWhere((ws) => ws.id == webspace.id);
      if (wasSelected) {
        _sites.selectedWebspaceId = kAllWebspaceId;
      }
    });
    if (wasSelected) {
      await _setCurrentIndex(null);
      if (!mounted) return;
    }
    await _saveWebspaces();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();
  }

  void _selectWebspace(Webspace webspace) async {
    if (_sites.selectedWebspaceId == webspace.id) {
      _scaffoldKey.currentState?.openDrawer();
      return;
    }

    // Version counter guards against rapid taps: if another call arrives
    // while we are awaiting, the stale call will detect the version mismatch
    // and bail out instead of corrupting state.
    final version = ++_selectWebspaceVersion;

    // Signal that a webspace switch is in progress. Site selection (onTap)
    // awaits this so the unload finishes before any new site is loaded.
    final completer = Completer<void>();
    _webspaceSwitchCompleter = completer;

    try {
      final previousIndices = _sites.filteredIndices().toSet();

      setState(() {
        _sites.selectedWebspaceId = webspace.id;
      });

      // Open drawer immediately so the user sees instant feedback on tap
      _scaffoldKey.currentState?.openDrawer();

      final newIndices = _sites.filteredIndices().toSet();

      // Only unload sites when online - preserve live webviews when offline
      // so users can still view cached content
      final online = await ConnectivityService.instance.isOnline();
      if (!mounted || version != _selectWebspaceVersion) return;

      if (online) {
        final plan = _residencyPlan(WebspaceSwitched(
          previous: previousIndices,
          next: newIndices,
        ));
        if (!await _applyResidency(plan,
            isStale: () => !mounted || version != _selectWebspaceVersion)) {
          return;
        }
      } else {
        LogTag.webspaceSwitch.debug('Offline - preserving loaded webviews');
      }

      setState(() {});
      await _saveSelectedWebspaceId();
      await _saveCurrentIndex();
    } finally {
      completer.complete();
      if (_webspaceSwitchCompleter == completer) {
        _webspaceSwitchCompleter = null;
      }
    }
  }

  void _reorderWebspaces(int oldIndex, {required int newIndex}) {
    // Don't allow reordering if "All" is involved (it stays at index 0)
    if (oldIndex == 0 || newIndex == 0) return;

    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final webspace = _sites.webspaces.removeAt(oldIndex);
      _sites.webspaces.insert(newIndex, webspace);
    });
    _saveWebspaces();
  }

  Future<void> _exportSettings() async {
    final prefs = await SharedPreferences.getInstance();
    // The global proxy password is in secure storage, not in the prefs
    // value `readExportedAppPrefs` reads — and per PWD-005 we do NOT
    // re-inject it for export (same as secure cookies).
    // ARCH-010: exports never include archive-tier state, even when an
    // archive is open. Filter on `isArchiveTier` so the export bytes
    // match what a user with zero archives would produce.
    final appTierModels =
        _sites.models.where((m) => !m.isArchiveTier).toList();

    final extraSections = await _archives.sectionsForExport();
    if (!mounted) return;

    await SettingsBackupService.exportAndSave(
      context,
      webViewModels: appTierModels,
      webspaces: ArchiveMembershipEngine.persistable(
        _sites.webspaces,
        archivedSiteIds: _archivedSiteIds,
      ),
      themeMode: _themeSettings.toStorageIndex(),
      globalPrefs: readExportedAppPrefs(prefs),
      selectedWebspaceId: _sites.selectedWebspaceId,
      currentIndex: _sites.current != null &&
              _sites.current! < appTierModels.length
          ? _sites.current
          : null,
      suggestedSites: _suggestedSites
          .map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
          .toList(),
      globalUserScripts: _globalUserScripts.map((s) => s.toJson()).toList(),
      // User intent for the downloaded-data blockers: the chosen DNS
      // severity level and the content-blocker list selection. The blobs
      // themselves stay machine state; the user re-downloads after import.
      dnsBlockLevel: DnsBlockService.instance.level,
      contentBlockerLists: ContentBlockerService.instance.exportListSelection(),
      extraSections: extraSections,
    );
  }

  /// uBO trusts a site by switching all filtering off on it; the per-site
  /// content-blocker toggle is the equivalent here. Archive-tier sites are
  /// left alone (ARCH-006), and so are sites whose Tracking Protection
  /// would hold the blocker on regardless.
  Future<List<UboTrustedSite>> _trustUboHosts(Set<String> hosts,
      {required bool apply}) async {
    final matched = <WebViewModel>[];
    for (final m in _sites.models) {
      if (m.isArchiveTier || !m.contentBlockEnabled) continue;
      if (m.trackingProtectionEnabled) continue;
      final host = Uri.tryParse(m.initUrl)?.host ?? '';
      if (host.isNotEmpty && hostTrustedBy(host, trustedHosts: hosts)) {
        matched.add(m);
      }
    }
    final result = [
      for (final m in matched)
        UboTrustedSite(m.getDisplayName(), host: Uri.parse(m.initUrl).host)
    ];
    if (apply && matched.isNotEmpty) {
      setState(() {
        for (final m in matched) {
          m.contentBlockEnabled = false;
          m.disposeWebView();
        }
      });
      await _commitSites(const SitesEdited());
    }
    return result;
  }

  Future<void> _importSettings() async {
    final backup = await SettingsBackupService.pickAndImport(context);
    if (backup == null) {
      return;
    }

    final sitesCount = backup.sites.length;
    final webspacesCount = backup.webspaces.length;
    final exportDate = backup.exportedAt.toLocal().toString().split('.')[0];

    final loc = AppLocalizations.of(context);
    final exportedLabel = loc.homeImportExportedLabel(exportDate);
    // State the backup installs that acts on its own once restored: the
    // app-wide proxy captures every DEFAULT site including webview traffic,
    // and a user script runs at document start with full page privileges.
    // Neither is visible in a site list, so the dialog has to name them.
    final incomingGlobalProxy = backupGlobalProxyAddress(backup);
    final incomingScriptCount = backupUserScriptCount(backup);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeImportSettingsTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.homeImportSettingsConfirm(sitesCount, webspacesCount)),
              SizedBox(height: 12),
              Text(
                exportedLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (incomingGlobalProxy != null) ...[
                SizedBox(height: 12),
                Text(loc.homeImportGlobalProxyWarning(incomingGlobalProxy)),
              ],
              if (incomingScriptCount > 0) ...[
                SizedBox(height: 12),
                Text(loc.homeImportUserScriptsWarning(incomingScriptCount)),
              ],
              SizedBox(height: 16),
              Text(
                loc.homeImportSettingsSessionsNote,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.homeImportAction),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    // Decide the whole import BEFORE touching live state: a site entry that
    // does not parse throws here, and a malformed/hostile backup would
    // otherwise leave the user with their sites already cleared and the
    // restore half-done.
    final SettingsImportPlan plan;
    try {
      plan = planSettingsImport(backup, stateSetterF: () {
        setState(() {});
      });
    } catch (e) {
      LogTag.import.error('Aborted import; live state left intact: $e');
      _toast((loc) => loc.homeImportInvalidBackup);
      return;
    }

    // Applied and persisted in one step, before any site activates, so a pref
    // the backup does not name reads the same before and after a restart.
    // Per PWD-005 the backup carries no proxy password: the user re-enters
    // it on the proxy settings screen, as they re-log into sites whose secure
    // cookies were stripped.
    await writeExportedAppPrefs(
        await SharedPreferences.getInstance(), values: plan.appPrefs);
    if (!mounted) return;
    // Every service that reads those prefs reloads before the sites commit,
    // so the Tor refcount and a DEFAULT site's first load see the imported
    // app-wide proxy, not the one it replaces.
    await DeveloperModeService.instance.reload();
    await TorService.instance.externalAddressChanged();
    await TorService.instance.runtimeChoiceChanged();
    // The imported value is password-less; the in-memory proxy follows it
    // without an app restart.
    final reloadedPrefs = await SharedPreferences.getInstance();
    await GlobalOutboundProxy.update(readGlobalOutboundProxy(reloadedPrefs));
    await ProxyLibrary.reloadAfterImport();
    // The downloaded-data blockers' user intent: the selection only, never
    // the blob, which the user re-downloads from App Settings.
    if (plan.dnsBlockLevel != null) {
      await DnsBlockService.instance.applyImportedLevel(plan.dnsBlockLevel!);
    }
    if (plan.contentBlockerLists != null) {
      await ContentBlockerService.instance
          .importListSelection(plan.contentBlockerLists!);
    }
    if (!mounted) return;
    _themeSettings = AppThemeSettings.fromStorageIndex(plan.themeStorageIndex);
    await _commitSites(SitesReplaced(
      sites: plan.sites,
      webspaces: plan.webspaces,
      selectedWebspaceId: plan.selectedWebspaceId,
    ));
    if (!mounted) return;

    final indexToRestore = plan.currentIndex;
    // With no site activated, _setCurrentIndex never reaches
    // _restoreCookiesForSite, so the previously active site's cookies would
    // stay in the native jar. Legacy engine only: container-mode sites never
    // shared that jar, and an unscoped clear issued while live containers
    // exist is the shape BUG-007 turned into a wiped session.
    if (indexToRestore == null && !_sites.useContainers) {
      await _cookieManager.deleteAllCookies();
    }
    await _setCurrentIndex(indexToRestore);
    if (!mounted) return;
    setState(() {});
    widget.onThemeSettingsChanged(_themeSettings);

    final importedCounts = _background.counts();
    if (importedCounts.enabled > 0) {
      BackgroundLog.instance.record(
        LogTag.siteUnload,
        message:
            'settings import: ${importedCounts.enabled} notification sites, '
            '${importedCounts.loaded} loaded until opened or the next launch',
        level: LogLevel.warning,
      );
    }
    await _saveThemeSettings();
    await _saveSelectedWebspaceId();
    await _saveCurrentIndex();

    if (plan.globalUserScripts != null) {
      _globalUserScripts = plan.globalUserScripts!;
    }
    await _saveGlobalUserScripts();

    if (plan.suggestedSites != null) {
      _suggestedSites = [
        for (final s in plan.suggestedSites!)
          SiteSuggestion(name: s.name, url: s.url, domain: s.domain),
      ];
      await suggested_sites.saveSuggestedSites(_suggestedSites);
    }

    final webViewTheme = _themeSettings.themeMode.webViewTheme;
    for (var webViewModel in _sites.models) {
      await webViewModel.setTheme(webViewTheme);
    }

    if (mounted) {
      final loc = AppLocalizations.of(context);
      final hints = <String>[
        if (plan.proxyPasswordsNeeded) loc.homeImportProxyPasswordsHint,
        if (plan.blocklistsNeedDownload) loc.homeImportBlocklistRedownloadHint,
      ];
      _toast(
        (loc) => hints.isEmpty
            ? loc.homeSettingsImportedSuccess
            : loc.homeSettingsImportedWithHints(hints.join(' ')),
        duration: Duration(seconds: hints.isEmpty ? 4 : 6),
      );
    }

    // If the backup carries encrypted sections, offer to restore them
    // by passphrase. Each prompt restores the section(s) matching the
    // entered passphrase; remaining ones can be restored by entering
    // another passphrase, or skipped by cancelling.
    if (plan.extraSections.isNotEmpty && mounted) {
      await _archives.restoreSections(plan.extraSections);
    }
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
  /// navigation passes through neither `_setCurrentIndex` nor `onControllerReady`
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
      // _setCurrentIndex when index == _sites.current, so nothing would re-add
      // it or recreate the disposed webview.
      if (i == _sites.current) {
        m.disposeWebView();
      } else {
        await _unloadSite(i, reason: UnloadReason.homeReset);
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
        onMoveSite: _canReorderCurrentView ? _moveSiteInTabsSheet : null,
        wayBack: _tabs.wayBackFrom(_sites.models[_sites.current!]),
      ),
    );
  }

  /// A site heading dropped on another in the Tabs sheet (TAB-016): the same
  /// reorder the drawer grid and the tab strip make. Returns the sheet's sites
  /// afresh, since reordering "All" renumbers them.
  List<TabsSheetSite>? _moveSiteInTabsSheet(String siteId,
      {required String ontoSiteId}) {
    if (_tabs.busy || !_canReorderCurrentView) return null;
    final order = _sites.filteredIndices();
    int at(String id) => order.indexWhere((i) =>
        i >= 0 && i < _sites.models.length && _sites.models[i].siteId == id);
    final from = at(siteId);
    final to = at(ontoSiteId);
    if (from < 0 || to < 0 || from == to) return null;
    _reorderSite(from, newListIndex: to);
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
    final loc = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              enabled: inDomain || tabRoute != null,
              leading: const Icon(Icons.tab),
              title: Text(loc.tabsOpenInNewTab),
              subtitle: inDomain
                  ? null
                  : tabHost != null
                      ? Text(loc.tabsRunsAs(tabHost.getDisplayName()))
                      : tabRoute == null
                          ? Text(loc.tabsLinkOutsideSite(uri.host))
                          : null,
              onTap: () {
                Navigator.of(ctx).pop();
                if (tabRoute is DispatchShowPicker) {
                  unawaited(_links.showOutboundPicker(model,
                      source: identity,
                      action: tabRoute,
                      url: uri,
                      parked: true));
                } else if (inDomain) {
                  // A sibling of the tab on screen: same container, and when
                  // that tab follows an opener's switch (LIR-034), so does it.
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
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(loc.commonOpen),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(_links.openLinkAsTapped(index, url: url));
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(loc.commonCopy),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: url));
              },
            ),
          ],
        ),
      ),
    );
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
      _enterFullscreen();
    }
    _commitSites(const SitesEdited());
  }

  String _getThemeTooltip(AppLocalizations loc) {
    final modeName = _themeSettings.themeMode == ThemeMode.system
        ? loc.homeThemeModeSystem
        : _themeSettings.themeMode == ThemeMode.light
            ? loc.homeThemeModeLight
            : loc.homeThemeModeDark;
    final colorName = _themeSettings.accentColor == AccentColor.blue
        ? loc.homeThemeColorBlue
        : loc.homeThemeColorGreen;
    return loc.homeThemeTooltip(modeName, colorName);
  }

  /// The one way the theme changes: the app, its saved settings and every
  /// site's webview follow.
  Future<void> _applyThemeSettings(AppThemeSettings next) async {
    setState(() => _themeSettings = next);
    widget.onThemeSettingsChanged(next);
    await _saveThemeSettings();
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
          currentSettings: _themeSettings,
          proxyRouterRunsHere: ProxyRouterService.canRunHere(
              useContainers: _sites.useContainers),
          externalTorRunsHere: externalTorRunsHere,
          siteNames: _siteNames(),
          onSettingsChanged: _applyThemeSettings,
          onExportSettings: _exportSettings,
          onImportSettings: _importSettings,
          onTrustUboHosts: _trustUboHosts,
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
          globalUserScripts: _globalUserScripts,
          onGlobalUserScriptsChanged: (scripts) {
            _globalUserScripts = scripts;
            _saveGlobalUserScripts();
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
              onDoubleTap: _toggleFullscreen,
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
          : Text(_sites.selectedWebspaceId != null
              ? _sites.webspaces.firstWhere(
                  (ws) => ws.id == _sites.selectedWebspaceId,
                  orElse: () => Webspace(name: 'Unknown'),
                ).name
              : loc.homeNoWebspaceSelected),
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
          mode: _themeSettings.themeMode,
          tooltip: _getThemeTooltip(loc),
          onChanged: (mode) => _applyThemeSettings(
              _themeSettings.copyWith(themeMode: mode)),
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
          PopupMenuButton<SiteMenuAction>(
            itemBuilder: (context) =>
                _siteMenuItems(context, placement: _SiteMenuPlacement.appBar),
            onSelected: _onSiteMenuAction,
          ),
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
    if (_isFullscreen) {
      if (AppPref.tabStripInFullscreen.value) return true;
      return AppPref.tabBarButton.value && _tabBarOverlayVisible;
    }
    return AppPref.showTabStrip.value || (AppPref.tabBarButton.value && _tabBarOverlayVisible);
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
    if (_tabBarOverlayVisible) return false;
    if (_isFullscreen) return !AppPref.tabStripInFullscreen.value;
    return !AppPref.showTabStrip.value;
  }

  /// Build the tab strip shown in bottomNavigationBar.
  /// This stays at the screen bottom and doesn't need to be above the keyboard.
  Widget? _buildTabStrip() {
    if (!_tabStripShown) return null;

    // Hide when keyboard is open - it's not needed during text input
    if (MediaQuery.of(context).viewInsets.bottom > 0) {
      return null;
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filteredIndices = _sites.filteredIndices();

    return SafeArea(
      top: false,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: isDark ? Color(0xFF1E1E1E) : Color(0xFFF5F5F5),
          border: Border(
            top: BorderSide(
              color: isDark ? Color(0xFF3E3E3E) : Color(0xFFE0E0E0),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            // When the strip was revealed by the fullscreen tab-bar button,
            // its dismiss control lives inside the bar (not as a separate
            // floating cross above it).
            if (_tabBarOverlayVisible)
              IconButton(
                icon: const Icon(Icons.close),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  setState(() {
                    _tabBarOverlayVisible = false;
                  });
                  _surface.nudge('tab-overlay-hide');
                },
              ),
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: filteredIndices.length,
                padding: EdgeInsets.symmetric(horizontal: 4),
                itemBuilder: (context, listIndex) {
                  return _buildTabStripItem(context,
                      listIndex: listIndex,
                      filteredIndices: filteredIndices,
                      theme: theme,
                      isDark: isDark);
                },
              ),
            ),
            _buildBottomPopupMenu(),
          ],
        ),
      ),
    );
  }

  /// One tab in the bottom strip. Draggable-to-reorder when the current view
  /// supports reordering (a named webspace or "All") and there is more than
  /// one tab; a plain tappable chip otherwise. Uses a raw [Listener] for tap
  /// detection rather than [GestureDetector] so the tap doesn't lose the
  /// gesture-arena fight with [LongPressDraggable] (same pattern as the
  /// drawer grid tiles).
  Widget _buildTabStripItem(
    BuildContext context, {
    required int listIndex,
    required List<int> filteredIndices,
    required ThemeData theme,
    required bool isDark,
  }) {
    final siteIndex = filteredIndices[listIndex];
    final siteModel = _sites.models[siteIndex];
    final isActive = siteIndex == _sites.current;
    final content = _buildTabStripItemContent(siteModel,
        isActive: isActive, theme: theme, isDark: isDark);

    void handleTap() {
      // Tapping the chip of the site already on screen opens its tab list —
      // the strip switches sites, and within a site the tabs are what is left
      // to switch between (TAB-008).
      if (isActive) {
        unawaited(_showTabsSheet());
        return;
      }
      () async {
        await _setCurrentIndex(siteIndex);
        if (!mounted) return;
        setState(() {
          _tabBarOverlayVisible = false;
        });
        _saveCurrentIndex();
      }();
    }

    if (!_canReorderCurrentView || filteredIndices.length < 2) {
      return GestureDetector(onTap: handleTap, child: content);
    }

    Offset? pointerDownPos;
    Duration? pointerDownTime;
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != listIndex,
      onAcceptWithDetails: (details) => _reorderSite(details.data, newListIndex: listIndex),
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return LongPressDraggable<int>(
          data: listIndex,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.85, child: content),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: content),
          child: Container(
            decoration: isHovered
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  )
                : null,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                pointerDownPos = event.position;
                pointerDownTime = event.timeStamp;
              },
              onPointerUp: (event) {
                if (pointerDownPos != null) {
                  final distance = (event.position - pointerDownPos!).distance;
                  final duration = event.timeStamp - pointerDownTime!;
                  if (distance < 20 &&
                      duration < const Duration(milliseconds: 300)) {
                    handleTap();
                  }
                }
                pointerDownPos = null;
                pointerDownTime = null;
              },
              onPointerCancel: (_) {
                pointerDownPos = null;
                pointerDownTime = null;
              },
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabStripItemContent(
    WebViewModel siteModel, {
    required bool isActive,
    required ThemeData theme,
    required bool isDark,
  }) {
    return Container(
      constraints: BoxConstraints(maxWidth: AppPref.tabMaxWidth.value.toDouble()),
      margin: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer
            : (isDark ? Color(0xFF2A2A2A) : Colors.white),
        borderRadius: BorderRadius.circular(8),
        border: isActive
            ? Border.all(color: theme.colorScheme.primary, width: 1.5)
            : Border.all(
                color: isDark ? Color(0xFF3E3E3E) : Color(0xFFE0E0E0),
                width: 0.5,
              ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UnifiedFaviconImage(
            url: siteModel.initUrl,
            size: 16,
            proxy: siteModel.outboundProxySettings,
            customIcon: siteModel.customIconPng,
            persist: !siteModel.isArchiveTier,
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              siteModel.getDisplayName(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
          ),
          // Tab count, only once there is more than one: a site with a single
          // tab looks exactly as it did before tabs existed (TAB-008).
          if (_tabs.enabledFor(siteModel) && siteModel.tabs.length > 1)
            TabCountPill(count: siteModel.tabs.length, active: isActive),
        ],
      ),
    );
  }

  /// Build the URL bar and find toolbar, placed in the body so that
  /// resizeToAvoidBottomInset keeps them above the keyboard.
  Widget? _buildInputBar() {
    if (_isFullscreen) return null;
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

  /// Popup menu button for use in the bottom bar when tab strip is enabled.
  Widget _buildBottomPopupMenu() {
    return PopupMenuButton<SiteMenuAction>(
      icon: Icon(Icons.more_vert, size: 20),
      padding: EdgeInsets.zero,
      tooltip: AppLocalizations.of(context).homeMenuTooltip,
      itemBuilder: (context) =>
          _siteMenuItems(context, placement: _SiteMenuPlacement.bottomBar),
      onSelected: _onSiteMenuAction,
    );
  }

  List<PopupMenuEntry<SiteMenuAction>> _siteMenuItems(
    BuildContext menuContext, {
    required _SiteMenuPlacement placement,
  }) {
    final loc = AppLocalizations.of(menuContext);
    return [
      _siteMenuNavRow(menuContext, loc: loc),
      PopupMenuDivider(),
      for (final action in SiteMenuAction.values)
        if (_siteMenuEntry(action, placement: placement, loc: loc)
            case (final icon, final label))
          PopupMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(icon),
                SizedBox(width: 8),
                Flexible(child: Text(label)),
              ],
            ),
          ),
    ];
  }

  /// Icon and label of [action] in the menu at [placement], or null where
  /// that menu does not offer it.
  (IconData, String)? _siteMenuEntry(
    SiteMenuAction action, {
    required _SiteMenuPlacement placement,
    required AppLocalizations loc,
  }) =>
      switch (action) {
        SiteMenuAction.newTab =>
          _tabs.enabledAt(_sites.current) ? (Icons.add, loc.tabsNewTab) : null,
        SiteMenuAction.backToWebspaces =>
          placement == _SiteMenuPlacement.bottomBar
              ? (Icons.arrow_back, loc.homeBackToWebspaces)
              : null,
        SiteMenuAction.search => (Icons.search, loc.homeFindMenu),
        // Where the site has tabs, web search lives in the Tabs sheet.
        SiteMenuAction.webSearch =>
          _tabs.featureEnabled && !_tabs.enabledAt(_sites.current)
              ? (Icons.travel_explore, loc.webSearchMenu)
              : null,
        SiteMenuAction.toggleUrlBar => AppPref.showUrlBar.value
            ? (Icons.visibility_off, loc.homeHideUrlBarMenu)
            : (Icons.visibility, loc.homeShowUrlBarMenu),
        SiteMenuAction.fullscreen => _isFullscreen
            ? (Icons.fullscreen_exit, loc.homeExitFullScreenMenu)
            : (Icons.fullscreen, loc.homeFullScreenMenu),
        // Manual escape hatch for the recurring Android blank surface
        // (BUG-001 / PAUSE-028): every automatic trigger is an enumerated
        // code path, and the user is the only one who can see a path nobody
        // enumerated. Android-only, where the nudge is not a no-op, and
        // behind developer mode: it is a diagnostic, not something to meet
        // by accident.
        SiteMenuAction.repaint =>
          hostIsAndroid && DeveloperModeService.instance.enabled
              ? (Icons.format_paint, loc.commonRepaintScreen)
              : null,
        SiteMenuAction.settings => (Icons.settings, loc.homeSettingsMenu),
        SiteMenuAction.devTools => (Icons.code, loc.homeDeveloperToolsMenu),
        SiteMenuAction.addToHome => switch (_sites.shown) {
            final shown? when _shortcuts.offersShortcutFor(shown) =>
              (Icons.add_to_home_screen, loc.homeHomeShortcutMenu),
            _ => null,
          },
      };

  PopupMenuItem<SiteMenuAction> _siteMenuNavRow(
    BuildContext menuContext, {
    required AppLocalizations loc,
  }) {
    final model = _sites.current != null ? _sites.models[_sites.current!] : null;
    final loading = model?.isLoading ?? false;
    return PopupMenuItem(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back),
            tooltip: loc.homeGoBackTooltip,
            onPressed: () {
              Navigator.pop(menuContext);
              () async {
                final controller = getController();
                if (controller != null) {
                  final canGoBack = await controller.canGoBack();
                  if (canGoBack) {
                    await _goBackAndRepaint(controller);
                  }
                }
              }();
            },
          ),
          IconButton(
            icon: Icon(Icons.home),
            tooltip: loc.homeGoToHomeTooltip,
            onPressed: () {
              Navigator.pop(menuContext);
              _goHome();
            },
          ),
          IconButton(
            icon: Icon(Icons.share),
            tooltip: loc.commonShare,
            onPressed: () {
              Navigator.pop(menuContext);
              if (_sites.current != null && _sites.current! < _sites.models.length) {
                final model = _sites.models[_sites.current!];
                final url = model.currentUrl;
                SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
              }
            },
          ),
          IconButton(
            icon: Icon(loading ? Icons.close : Icons.refresh),
            tooltip: loading ? loc.homeStopTooltip : loc.homeRefreshTooltip,
            onLongPress: _tabs.enabledAt(_sites.current)
                ? () {
                    Navigator.pop(menuContext);
                    final index = _sites.current;
                    if (index != null) unawaited(_tabs.duplicateTab(index));
                  }
                : null,
            onPressed: () {
              Navigator.pop(menuContext);
              if (loading) {
                _stopCurrentSiteLoading();
              } else {
                _refreshCurrentSite();
              }
            },
          ),
        ],
      ),
    );
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
        await _setCurrentIndex(null);
        if (!mounted) return;
        setState(() {});
        await _saveSelectedWebspaceId();
        await _saveCurrentIndex();
      case SiteMenuAction.search:
        _toggleFind();
      case SiteMenuAction.webSearch:
        await _links.webSearch();
      case SiteMenuAction.toggleUrlBar:
        await AppPref.showUrlBar.set(!AppPref.showUrlBar.value);
      case SiteMenuAction.fullscreen:
        _toggleFullscreen();
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
              globalUserScripts: _globalUserScripts,
              onSimulateBackgroundRefresh: _background.wake,
            ),
          ),
        ));
      case SiteMenuAction.addToHome:
        if (model != null) await _shortcuts.addToHome(model);
    }
  }

  /// [deepLinkQrSettings] is a decoded `webspace://qr/` payload that arrived
  /// from outside the app. Both QR entry points (this one and the in-app
  /// scanner, which returns `{'qrSettings': ...}` from `AddSiteScreen`) pass
  /// through the same review gate below, and a payload the app did not ask
  /// for never becomes the visible site.
  Future<void> _addSite({
    String? initialUrl,
    Map<String, dynamic>? deepLinkQrSettings,
  }) async {
    Object? result;
    if (deepLinkQrSettings != null) {
      result = {'qrSettings': deepLinkQrSettings};
    } else {
      result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AddSiteScreen(
            themeMode: _themeSettings.themeMode,
            onThemeModeChanged: (mode) => _applyThemeSettings(
                _themeSettings.copyWith(themeMode: mode)),
            suggestions: _suggestedSites,
            onSuggestionsChanged: (sites) {
              _suggestedSites = sites;
              suggested_sites.saveSuggestedSites(sites);
            },
            initialUrl: initialUrl,
          ),
        ),
      );
    }
    if (result == null || result is! Map<String, dynamic>) return;
    if (!mounted) return;

    final stateSetter = () { setState((){}); };
    late WebViewModel model;
    final resultQrSettings = result['qrSettings'] as Map<String, dynamic>?;

    if (resultQrSettings != null) {
      final accepted = await _confirmQrSiteSettings(resultQrSettings);
      if (!accepted || !mounted) return;
      model = WebViewModel.fromJson(
        SiteSettingsQrCodec.hydrateForFromJson(resultQrSettings),
        stateSetterF: stateSetter,
      );
      if (model.name.isEmpty) {
        final pageTitle = await getPageTitle(
          model.initUrl,
          proxy: model.outboundProxySettings,
        );
        if (!mounted) return;
        if (pageTitle != null && pageTitle.isNotEmpty) {
          model.name = pageTitle;
          model.pageTitle = pageTitle;
        }
      } else {
        model.pageTitle = model.name;
      }
    } else {
      final url = result['url'] as String;
      final customName = result['name'] as String;
      final incognito = result['incognito'] as bool? ?? false;
      final htmlContent = result['htmlContent'] as String?;

      // Try to fetch page title if custom name not provided (skip for local files)
      String? pageTitle;
      if (customName.isEmpty && htmlContent == null) {
        pageTitle = await getPageTitle(url);
        if (!mounted) return;
      }

      model = WebViewModel(
        initUrl: url,
        incognito: incognito,
        stateSetterF: stateSetter,
      );
      if (customName.isNotEmpty) {
        model.name = customName;
        model.pageTitle = customName;
      } else if (pageTitle != null && pageTitle.isNotEmpty) {
        model.name = pageTitle;
        model.pageTitle = pageTitle;
      }

      // Imported HTML files are the only copy of the user's data, so they
      // go into HtmlImportStorage (persistent) rather than HtmlCacheService
      // (cleared on app upgrade). The webview reads from the import store
      // for `initialHtml` on creation.
      if (htmlContent != null && !incognito) {
        await HtmlImportStorage.instance
            .saveHtml(model.siteId, html: htmlContent, url: url);
      }
    }

    await _registerNewSite(model, activate: deepLinkQrSettings == null);
  }

  /// Mandatory review of a QR-borne site configuration before it is created.
  /// The payload is authored by whoever printed the code, reaches us from any
  /// app or web page via the exported `webspace://` scheme, and can turn every
  /// protection off, point the site at a proxy, and name it anything.
  Future<bool> _confirmQrSiteSettings(Map<String, dynamic> qr) async {
    final loc = AppLocalizations.of(context);
    final url = qr['initUrl'] as String? ?? '';
    final name = (qr['name'] as String?) ?? extractDomain(url);
    final proxy = SiteSettingsQrCodec.reviewProxy(qr);
    final proxyAddress = proxy?.address ?? '';
    final proxyLabel = proxy == null
        ? null
        : proxy.type == ProxyType.TOR
            ? loc.torStatusTitle
            : proxyAddress.isNotEmpty
                ? proxyAddress
                : proxy.type.name;
    bool turnsOff(String key) => qr[key] == false;
    bool turnsOn(String key) => qr[key] == true;
    final weakened = <String>[
      if (turnsOff('trackingProtectionEnabled')) loc.siteSettingsTrackingProtection,
      if (turnsOff('clearUrlEnabled')) loc.siteSettingsClearUrls,
      if (turnsOff('dnsBlockEnabled')) loc.siteSettingsDnsBlocklist,
      if (turnsOff('contentBlockEnabled')) loc.siteSettingsContentBlocker,
      if (turnsOff('localCdnEnabled')) loc.siteSettingsLocalCdn,
      // A level below the app-wide one, or a filter list switched off, weakens
      // the blockers without turning either toggle off. Unnamed, a QR could
      // relax protection while the review reported nothing.
      if (qr['dnsBlockLevel'] is int &&
          (qr['dnsBlockLevel'] as int) < DnsBlockService.instance.level)
        loc.siteSettingsDnsBlocklistLevel,
      if (qr['disabledFilterLists'] is List &&
          (qr['disabledFilterLists'] as List).isNotEmpty)
        loc.siteSettingsContentBlockerLists,
    ];
    final granted = <String>[
      if (turnsOn('thirdPartyCookiesEnabled')) loc.siteSettingsThirdPartyCookies,
      if (turnsOn('notificationsEnabled')) loc.siteSettingsNotifications,
      if (turnsOn('backgroundAudioEnabled')) loc.siteSettingsBackgroundAudio,
      if (turnsOn('kioskMode')) loc.siteSettingsKioskMode,
      if (qr['locationMode'] is String && qr['locationMode'] != LocationMode.off.name)
        loc.siteSettingsGeolocation,
    ];
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.homeQrReviewTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.homeQrReviewBody),
              SizedBox(height: 12),
              Text(loc.homeQrReviewUrl(url)),
              Text(loc.homeQrReviewName(name)),
              if (proxyLabel != null) Text(loc.homeQrReviewProxy(proxyLabel)),
              if (weakened.isNotEmpty) ...[
                SizedBox(height: 12),
                Text(loc.homeQrReviewTurnsOff(weakened.join(', '))),
              ],
              if (granted.isNotEmpty) ...[
                SizedBox(height: 12),
                Text(loc.homeQrReviewTurnsOn(granted.join(', '))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.qrApplyConfirm),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _editSite(int index) async {
    final model = _sites.models[index];
    final result = await showEditSiteDialog(context, site: model);
    if (result == null || !mounted) return;
    // Apply by the captured model identity, not the index: a concurrent
    // delete of a lower-indexed site while the dialog was open shifts
    // positions, so `index` could now target a different site. Bail if this
    // model was deleted meanwhile.
    if (!_sites.models.contains(model)) return;

    final (:name, :url, :icon) = result;
    if (icon != null) {
      setState(() => model.customIconPng = icon.png);
    }
    if (name.isNotEmpty) {
      setState(() => model.name = name);
    }

    if (url != model.initUrl) {
      // Snapshot belongs to the old URL; deleteCache must run before the
      // rebuild's getHtmlSync, which is why the sync in-memory eviction
      // (inside deleteCache) is fired before setState rather than awaited.
      final siteId = model.siteId;
      final deleteCache = HtmlCacheService.instance.deleteCache(siteId);
      setState(() {
        model.initUrl = url;
        model.currentUrl = url;
        model.webview = null; // Force recreation with new URL
        model.controller = null;
      });
      await deleteCache;
    }

    await _commitSites(const SitesEdited());
  }

  void _showSiteContextMenu(BuildContext context,
      {required int index, required Offset position}) {
    final filteredIndices = _sites.filteredIndices();
    final listIndex = filteredIndices.indexOf(index);
    final isArchiveSite =
        index >= 0 && index < _sites.models.length && _sites.models[index].isArchiveTier;
    // Show "Move to archive" for every app-tier site, regardless of
    // whether any archive is currently open. The handler always prompts
    // for a passphrase and opens-or-creates the matching archive — its
    // presence in the menu therefore reveals nothing about whether an
    // archive is currently open or whether any exist on disk.
    final canMoveToArchive = !isArchiveSite;

    final loc = AppLocalizations.of(context);
    PopupMenuItem<_SiteListAction> item(
      _SiteListAction action, {
      required IconData icon,
      required String label,
      Color? color,
    }) =>
        PopupMenuItem(
          value: action,
          child: ListTile(
            leading: Icon(icon, color: color),
            title: Text(label, style: TextStyle(color: color)),
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
        );
    showMenu<_SiteListAction>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      items: [
        item(_SiteListAction.edit, icon: Icons.edit, label: loc.commonEdit),
        item(_SiteListAction.delete, icon: Icons.delete, label: loc.commonDelete,
            color: Colors.red),
        if (_canReorderCurrentView && listIndex > 0)
          item(_SiteListAction.moveUp, icon: Icons.arrow_upward, label: loc.homeMoveUp),
        if (_canReorderCurrentView && listIndex >= 0 && listIndex < filteredIndices.length - 1)
          item(_SiteListAction.moveDown, icon: Icons.arrow_downward, label: loc.homeMoveDown),
        if (canMoveToArchive)
          item(_SiteListAction.moveToArchive, icon: Icons.archive_outlined,
              label: loc.homeMoveToArchive),
        if (isArchiveSite)
          item(_SiteListAction.moveOutOfArchive, icon: Icons.unarchive_outlined,
              label: loc.homeMoveOutOfArchive),
        if (isArchiveSite)
          item(_SiteListAction.closeArchive, icon: Icons.lock_outline,
              label: loc.homeCloseArchive),
      ],
    ).then((value) async {
      final site = index >= 0 && index < _sites.models.length
          ? _sites.models[index]
          : null;
      switch (value) {
        case null:
          return;
        case _SiteListAction.moveToArchive:
          if (site != null) await _archives.moveIn(site);
        case _SiteListAction.moveOutOfArchive:
          if (site != null) await _archives.moveOut(site);
        case _SiteListAction.closeArchive:
          if (site != null) await _archives.closeArchiveOf(site);
        case _SiteListAction.edit:
          await _editSite(index);
        case _SiteListAction.delete:
          await _deleteSite(context, index: index);
        case _SiteListAction.moveUp:
          _reorderSite(listIndex, newListIndex: listIndex - 1);
        case _SiteListAction.moveDown:
          _reorderSite(listIndex, newListIndex: listIndex + 1);
      }
    });
  }

  /// Whether the currently-selected view supports drag/menu reordering.
  /// Both a named webspace (reorders its `siteIds`) and the synthetic "All"
  /// view (reorders `_sites.models` globally) qualify; the null/home state
  /// does not.
  bool get _canReorderCurrentView => _sites.selectedWebspaceId != null;

  /// Reorder the site shown at [oldListIndex] to [newListIndex] within the
  /// current view. Dispatches to the per-webspace `siteIds` reorder for a
  /// named webspace, or the global `_sites.models` reorder for "All".
  /// [oldListIndex]/[newListIndex] are positions in `_sites.filteredIndices()`.
  void _reorderSite(int oldListIndex, {required int newListIndex}) {
    final filtered = _sites.filteredIndices();
    if (oldListIndex < 0 || oldListIndex >= filtered.length) return;
    if (newListIndex < 0 || newListIndex >= filtered.length) return;
    if (oldListIndex == newListIndex) return;
    if (_sites.selectedWebspaceId == kAllWebspaceId) {
      unawaited(_reorderAllSites(filtered[oldListIndex],
          newModelIndex: filtered[newListIndex]));
    } else {
      _reorderSiteInWebspace(oldListIndex, newListIndex: newListIndex);
    }
  }

  void _reorderSiteInWebspace(int oldListIndex, {required int newListIndex}) {
    final webspace = _sites.webspaces.cast<Webspace?>().firstWhere(
      (ws) => ws!.id == _sites.selectedWebspaceId,
      orElse: () => null,
    );
    if (webspace == null) return;
    if (oldListIndex < 0 || oldListIndex >= webspace.siteIds.length) return;
    if (newListIndex < 0 || newListIndex >= webspace.siteIds.length) return;
    setState(() {
      final movedSiteId = webspace.siteIds.removeAt(oldListIndex);
      webspace.siteIds.insert(newListIndex, movedSiteId);
      _sites.resolveWebspaceIndices();
    });
    _saveWebspaces();
  }

  /// Moves the site at [oldModelIndex] to [newModelIndex] in the "All"
  /// order. The IndexedStack children are keyed by siteId, so each webview
  /// keeps its State.
  Future<void> _reorderAllSites(int oldModelIndex,
      {required int newModelIndex}) async {
    if (oldModelIndex < 0 || oldModelIndex >= _sites.models.length) return;
    if (newModelIndex < 0 || newModelIndex >= _sites.models.length) return;
    if (oldModelIndex == newModelIndex) return;
    await _commitSites(SitesMoved(oldModelIndex, to: newModelIndex));
    await _saveCurrentIndex();
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

  Future<void> _deleteSite(BuildContext context, {required int index}) async {
    final loc = AppLocalizations.of(context);
    final siteName = _sites.models[index].getDisplayName();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.homeDeleteSiteTitle),
        content: Text(loc.homeDeleteSiteConfirm(siteName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonDelete),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (index >= _sites.models.length) return;

    final deletedModel = _sites.models[index];
    // HS-013: the tiles reaching the site, read before it goes.
    final reachingTiles = await _shortcuts.tilesReaching(deletedModel);
    if (!mounted) return;
    await _commitSites(SiteRemoved(deletedModel));
    await _shortcuts.siteDeleted(deletedModel, tiles: reachingTiles);

    if (!mounted) return;
    // closeDrawer() (not Navigator.pop): `context` belongs to the drawer tile
    // of the site just removed, so by now its element can be defunct and
    // Navigator.of would fail its null check — deterministically so when the
    // deleted site was the last tile. Idempotent, like the other drawer taps.
    _scaffoldKey.currentState?.closeDrawer();
  }

  /// A site tapped in the drawer, once a webspace switch in flight lands.
  Future<void> _openSiteFromDrawer(int index) async {
    // closeDrawer() (not Navigator.pop) is idempotent: a rapid second tap
    // won't pop the underlying page route once the drawer is already closing.
    _scaffoldKey.currentState?.closeDrawer();
    await _webspaceSwitchCompleter?.future;
    await _setCurrentIndex(index);
    if (!mounted) return;
    setState(() {});
    await _saveCurrentIndex();
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
        unawaited(_captureStateBytes(site));
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
      top: _isFullscreen,
      bottom: !hasTabStrip && inputBar == null,
      // Out of fullscreen, inset around a landscape display cutout so chrome
      // and content avoid the notch. In fullscreen let the webview fill the
      // cutout strip (with shortEdges cutout mode the window already extends
      // there); otherwise SafeArea would re-letterbox the space beside the
      // notch with the app background. github #457
      left: !_isFullscreen,
      right: !_isFullscreen,
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
                    accentColor: _themeSettings.accentColor,
                    onSelectWebspace: _selectWebspace,
                    onAddWebspace: _addWebspace,
                    onEditWebspace: _editWebspace,
                    onDeleteWebspace: _deleteWebspace,
                    onReorder: _reorderWebspaces,
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
                    when _isFullscreen && shown.isLoading)
                  FullscreenLoadBar(progress: shown.loadingProgress),
                // Back keeps its normal behaviour in full screen. KIOSK-003:
                // no exit handle in a locked session.
                if (_isFullscreen && !_kioskLocked)
                  FullscreenExitHandle(onExit: _exitFullscreen),
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
                        setState(() => _tabBarOverlayVisible = true);
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
    final loc = AppLocalizations.of(context);
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
      appBar: _isFullscreen ? null : _buildAppBar(),
      // KIOSK-002: no drawer when locked — removes the site grid, "back to
      // webspaces", add-site, and the auto app-bar hamburger / edge swipe.
      drawer: _kioskLocked ? null : Drawer(
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () async {
                        await _setCurrentIndex(null);
                        if (!mounted) return;
                        setState(() {});
                        await _saveSelectedWebspaceId();
                        await _saveCurrentIndex();
                        if (!mounted) return;
                        _scaffoldKey.currentState?.closeDrawer();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: Column(
                          children: [
                            AccentLogo(
                              accentColor: _themeSettings.accentColor,
                              size: 72,
                              brightness: Theme.of(context).brightness,
                            ),
                            SizedBox(height: 4),
                            Text(
                              _sites.selectedWebspaceId != null
                                  ? _sites.webspaces.firstWhere((ws) => ws.id == _sites.selectedWebspaceId, orElse: () => Webspace(name: 'Unknown')).name
                                  : loc.homeNoWebspace,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Semantics(
                      label: loc.homeBackToWebspaces,
                      button: true,
                      enabled: true,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 0),
                          minimumSize: Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () async {
                          await _setCurrentIndex(null);
                          if (!mounted) return;
                          setState(() {});
                          await _saveSelectedWebspaceId();
                          await _saveCurrentIndex();
                          if (!mounted) return;
                          _scaffoldKey.currentState?.closeDrawer();
                        },
                        icon: Icon(Icons.arrow_back, size: 16),
                        label: Text(loc.homeBackToWebspaces, style: TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _sites.selectedWebspaceId == null
                  ? Center(
                      child: Text(loc.homeSelectWebspaceToViewSites),
                    )
                  : () {
                      final filteredIndices = _sites.filteredIndices();
                      if (filteredIndices.isEmpty) {
                        return Center(
                          child: Text(loc.homeNoSitesInWebspace),
                        );
                      }

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final itemCount = filteredIndices.length;
                          const itemHeight = 88.0;
                          final availableHeight = constraints.maxHeight - 12; // padding (top: 4 + bottom: 8)
                          final maxRows = (availableHeight / itemHeight).floor().clamp(1, itemCount);

                          int crossAxisCount = 1;
                          if (itemCount > maxRows) {
                            crossAxisCount = (itemCount / maxRows).ceil().clamp(1, 4);
                          }

                          return GridView.builder(
                            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8, top: 4),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              mainAxisSpacing: 4,
                              crossAxisSpacing: 4,
                              mainAxisExtent: itemHeight,
                            ),
                            itemCount: itemCount,
                            itemBuilder: (BuildContext context, int listIndex) {
                              final index = filteredIndices[listIndex];
                              final site = _sites.models[index];
                              return SiteGridTile(
                                key: Key('site_$index'),
                                site: site,
                                listIndex: listIndex,
                                selected: _sites.current == index,
                                showTabCount: _tabs.enabledAt(index) &&
                                    site.tabs.length > 1,
                                onOpen: () => unawaited(_openSiteFromDrawer(index)),
                                onMenu: (context, {required globalPosition}) =>
                                    _showSiteContextMenu(context, index: index, position: globalPosition),
                                onReorder:
                                    _canReorderCurrentView ? (from, {required to}) => _reorderSite(from, newListIndex: to) : null,
                              );
                            },
                          );
                        },
                      );
                    }(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    _addSite();
                  },
                  icon: Icon(Icons.add),
                  label: Text(loc.homeAddSite),
                ),
              ),
            ),
            SizedBox(height: 8.0 + MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
      body: _buildBodyWithBottomBar(),
      bottomNavigationBar: _buildTabStrip(),
      floatingActionButton:
          !(_sites.current == null || _sites.current! >= _sites.models.length) ? null
          : FloatingActionButton(
              onPressed: () async {
                _addSite();
              },
              child: Icon(Icons.add),
            ),
    ),
    );
  }
}

/// What a site's overflow menu offers, in menu order.
enum SiteMenuAction {
  newTab,
  backToWebspaces,
  search,
  webSearch,
  toggleUrlBar,
  fullscreen,
  repaint,
  settings,
  devTools,
  addToHome,
}


/// What a site's long-press menu in the list offers.
enum _SiteListAction {
  edit,
  delete,
  moveUp,
  moveDown,
  moveToArchive,
  moveOutOfArchive,
  closeArchive,
}

/// Where a site's overflow menu sits: the app bar, or the bottom bar while
/// the tab strip is on.
enum _SiteMenuPlacement { appBar, bottomBar }

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
    await state._maybeSwitchToAllForSite(target, index: index);
  }

  @override
  Set<int> mismatchedWith(WebViewModel target) => {
        for (final unload in state
            ._residencyPlan(NestedOpening(state._sites.models.indexOf(target)))
            .unloads)
          state._sites.models.indexOf(unload.site),
      };

  @override
  Future<void> unload(int index) =>
      state._unloadSite(index, reason: UnloadReason.proxyMismatch);

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
  Future<void> activate(int index) => state._setCurrentIndex(index);
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
      state._captureStateForRestore(model);

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

class _OrphanSweepTargets implements OrphanSweepTargets {
  final _WebSpacePageState state;
  const _OrphanSweepTargets(this.state);

  @override
  Future<void> removeOrphans(OrphanStore store,
          {required Set<String> liveSiteIds}) =>
      switch (store) {
        OrphanStore.cookies =>
          state._cookieSecureStorage.removeOrphanedCookies(liveSiteIds),
        OrphanStore.proxyPasswords =>
          state._proxyPasswordStorage.removeOrphaned(liveSiteIds),
        OrphanStore.httpAuthCredentials =>
          HttpAuthSecureStorage.instance.removeOrphaned(liveSiteIds),
        OrphanStore.htmlCaches =>
          HtmlCacheService.instance.removeOrphanedCaches(liveSiteIds),
        OrphanStore.htmlImports =>
          HtmlImportStorage.instance.removeOrphanedImports(liveSiteIds),
        OrphanStore.webViewState =>
          state._stateStorage.removeOrphans(state._liveStateKeys(liveSiteIds)),
        OrphanStore.blockStatsSites =>
          BlockStatsService.instance.removeOrphanedSites(liveSiteIds),
        OrphanStore.siteIcons => SiteIconStore.instance.removeOrphans({
            for (final m in state._sites.models)
              if (liveSiteIds.contains(m.siteId) && !m.effectiveIncognito)
                m.initUrl,
          }),
      };

  @override
  Future<void> clearLegacyGlobalCookieJar() =>
      state._cookieManager.deleteAllCookies();
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
        LinkHost {
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
  }) =>
      _s._toast(message, duration: duration);

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
  Future<void> activate(int index) => _s._setCurrentIndex(index);

  @override
  void syncTorExitPin(Set<int> indices) => _s._network.syncTorExitPin(indices);

  @override
  WebViewHostHooks get webViewHooks => _s._webViewHooks;

  @override
  void enterFullscreen() => _s._enterFullscreen();

  @override
  void reapplyFullscreen() {
    if (_s._isFullscreen) _s._applyFullscreenSystemUi();
  }

  @override
  Future<bool> captureNavState(WebViewModel model) =>
      _s._captureStateBytes(model);

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
      _s._registerNewSite(model, activate: activate);

  @override
  Future<void> addSiteFromQr(Map<String, dynamic> settings) =>
      _s._addSite(deepLinkQrSettings: settings);

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
      _s._unloadSite(index, reason: reason);

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
  Future<void> saveCurrentIndex() => _s._saveCurrentIndex();

  @override
  Future<void> saveSelectedWebspace() => _s._saveSelectedWebspaceId();

  @override
  Future<void> revealSite(WebViewModel model, {required int index}) =>
      _s._maybeSwitchToAllForSite(model, index: index);

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
