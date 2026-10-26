import 'dart:async';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/localizations.dart';

import 'package:webspace/controllers/app_lifecycle_controller.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/back_gesture_controller.dart';
import 'package:webspace/controllers/background_sites_controller.dart';
import 'package:webspace/controllers/startup_controller.dart';
import 'package:webspace/controllers/nested_open_binding.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/controllers/fullscreen_controller.dart';
import 'package:webspace/controllers/keyboard_shortcut_controller.dart';
import 'package:webspace/controllers/link_controller.dart';
import 'package:webspace/controllers/site_network_controller.dart';
import 'package:webspace/controllers/shortcut_controller.dart';
import 'package:webspace/controllers/site_reset_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/activation_host.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_editing_controller.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/controllers/webspaces_controller.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_search.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/webspace_name.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/services/experimental_features_service.dart';
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
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/services/surface_route_observer.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/archive.dart' show Archive, ArchiveHandle;
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/services/nav_capture.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/nav_state_capture_debouncer.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/services/app_lifecycle_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_service.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/external_tor.dart';
import 'package:webspace/settings/tab_strip_edge.dart';
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
import 'package:webspace/widgets/launch_zoom.dart';
import 'package:webspace/widgets/link_prompts.dart';
import 'package:webspace/widgets/page_load_bar.dart';
import 'package:webspace/widgets/protection_shield_button.dart';
import 'package:webspace/widgets/shortcut_prompts.dart';
import 'package:webspace/services/surface_nudge_scope.dart';
import 'package:webspace/widgets/webspace_prompts.dart';
import 'package:webspace/widgets/webview_prompts.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/step_table.dart';

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

/// Test seam: the cold start of the current run, from the first frame to the
/// last step of [StartupController.restore], so a benchmark can time it.
@visibleForTesting
Future<void>? debugStartupRestore;

class WebSpacePage extends StatefulWidget {
  final Function(AppThemeSettings) onThemeSettingsChanged;
  final ProcessLaunch launch;

  WebSpacePage({required this.onThemeSettingsChanged, required this.launch});

  @override
  _WebSpacePageState createState() => _WebSpacePageState();
}

class _WebSpacePageState extends State<WebSpacePage>
    with WidgetsBindingObserver, RouteAware {
  final _libraryKey = GlobalKey<WebspaceLibraryState>();
  final _launchZoom = GlobalKey<LaunchZoomState>();
  final _urlBar = GlobalKey<UrlBarState>();
  bool get _folderLibraryEnabled => ExperimentalFeaturesService.instance
      .isEnabled(ExperimentalFeature.folderLibrary);
  final SiteRuntime _sites = SiteRuntime();
  late final ShortcutController _shortcuts = ShortcutController(_sites,
      host: _PageHost(this), prompts: DialogShortcutPrompts(context));
  late final SurfaceRepaintController _surface = SurfaceRepaintController(
    _PageHost(this),
    repaints: hostIsAndroid,
    traceSuffix: '',
  );
  late final BackGestureController _back =
      BackGestureController(host: _PageHost(this), surface: _surface);
  late final FullscreenController _fullscreen =
      FullscreenController(host: _PageHost(this), surface: _surface);
  late final KeyboardShortcutController _keys = KeyboardShortcutController(
      _sites, host: _PageHost(this), tabs: _tabs, resets: _resets, back: _back);
  late final SiteActivationController _activation = SiteActivationController(
    _sites,
    host: _PageHost(this),
    residency: _ResidencyHost(this),
    navStates: _stateStorage,
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
    prompts: DialogSiteEditingPrompts(context, shell: _shell),
    shell: _shell,
    shortcuts: _shortcuts,
    deletion: _deletion,
  );
  late final SiteDeletion _deletion = SiteDeletion(_sites, host: _PageHost(this));
  late final SiteSetCommit _commit = SiteSetCommit(_sites, host: _PageHost(this));
  late final PageOrphanSweep _sweep = PageOrphanSweep(
    _sites,
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
  );
  late final StartupController _startup = StartupController(
    _sites,
    launch: widget.launch,
    host: _PageHost(this),
    shell: _shell,
    siteStore: _siteStore,
    shortcuts: _shortcuts,
    activation: _activation,
    background: _background,
    sweep: _sweep,
  );
  late final SiteResetController _resets = SiteResetController(
    _sites,
    host: _PageHost(this),
    tabs: _tabs,
    activation: _activation,
  );
  late final BackupController _backup = BackupController(
    _sites,
    host: _PageHost(this),
    prompts: DialogBackupPrompts(context),
    shell: _shell,
    archives: _archives,
    background: _background,
  );
  late final ArchiveController _archives = ArchiveController(
    _sites,
    host: _PageHost(this),
    prompts: DialogArchivePrompts(context),
    cookieStore: _cookieSecureStorage,
    proxyPasswords: _proxyPasswordStorage,
    navStates: _stateStorage,
    archive: Archive(),
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

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final _siteSettingsGuard = ReentryGuard();
  bool _isFindVisible = false;
  /// When true, a full-screen opaque mask covers every webview so the
  /// OS task-switcher / recents snapshot doesn't capture archive-tier
  /// content (ARCH-009). Set on `inactive`/`paused` when at least one
  /// archive is open; cleared on `resumed`. Apps without an open
  /// archive get the normal screenshot.
  bool _maskBackground = false;

  // AES-encrypted on-disk storage for per-site `controller.saveState()`
  // bytes. A 256-bit AES key in `FlutterSecureStorage`, per-site files under
  // `<docs>/webview_state/<siteId>.enc`. Bytes survive webspace
  // switches, LRU evictions, memory-pressure disposals, AND cold
  // starts (cleared on app-version upgrade alongside the key).
  //
  // Sites in [SiteLifecycleState.savedForRestore] have an entry here
  // per tab; re-activation reads the active tab's and queues it on the
  // model's `tabBinding`, tagged with that tab, so onControllerCreated can
  // apply it to the freshly-built controller.
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
    debugStartupRestore = _startup.restore();
    unawaited(_shortcuts.probeSupport());
    _shortcuts.start();
    _network.start();
    _fullscreen.start();
    _keys.start();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onAppPrefChanged() => _rebuild();

  /// Push the per-site settings screen for the site at [index].
  ///
  /// Three call sites want it: the two overflow menus, and the
  /// blocked-navigation interstitial, which has to reach the proxy row of
  /// the site it is covering (LEAK-010).
  Future<void> _openSiteSettings(WebViewModel model) async {
    if (!_sites.models.contains(model)) return;
    await _siteSettingsGuard.run(() async {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SettingsScreen(
            webViewModel: model,
            appTheme: _shell.theme.themeMode.webViewTheme,
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
              unawaited(_shell.saveGlobalUserScripts());
              _resets.resetAll();
            },
            onScriptsChanged: _resets.resetShown,
            onClearCookies: () => _clearSiteData(model),
            onSettingsSaved: _resets.settingsSaved,
            onProxyChanging: () => _beforeProxyChange(model),
          ),
        ),
      );
      if (!mounted) return;
      await _commitSites(const SiteSettingsClosed());
    });
  }

  /// A site's proxy changed in its settings. Its live webview takes the new
  /// rule at once, so the loaded sites it now contends with go first, as
  /// they would for its activation (PROXY-008).
  Future<void> _beforeProxyChange(WebViewModel model) async {
    final slot = _sites.models.indexOf(model);
    if (slot < 0 || model.controller == null) return;
    await _activation.applyResidency(
      _activation.residencyPlan(SlotIdentityChanged(slot)),
      isStale: () => !mounted,
    );
  }

  /// [_openSiteSettings] for the site [siteId] names, for call sites that
  /// carry the id rather than the site (the nested webview screen).
  Future<void> _openSiteSettingsById(SiteId? siteId) async {
    if (siteId == null) return;
    if (_sites.byId(siteId) case final model?) await _openSiteSettings(model);
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
  /// (`activate`), the controller was not recreated
  /// (`onControllerReady`), nothing navigated, and the app never left the
  /// foreground. See PAUSE-024 / BUG-001.
  @override
  void didPopNext() {
    _surface.nudge('route-return');
  }

  @override
  void dispose() {
    _startup.dispose();
    _background.dispose();
    _surface.dispose();
    _navStateDebouncer.dispose();
    _network.dispose();
    _shortcuts.dispose();
    AppPref.anyChange.removeListener(_onAppPrefChanged);
    _fullscreen.dispose();
    _keys.dispose();
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
    final state = WidgetsBinding.instance.lifecycleState;
    if (!AppLifecycleEngine.memoryPressureTrims(state)) {
      LogTag.lifecycle.debug(
          'memory pressure while ${state?.name ?? 'unreported'}: '
          'leaving the screen, nothing trimmed (PAUSE-034)');
      return;
    }
    // Trim one loaded site per event so the system controls the curve: if
    // pressure persists the callback fires again and we evict the next
    // victim. The active site is hard-protected; sites in the active
    // webspace are soft-keep (evicted only after every other candidate).
    unawaited(_activation.memoryPressure());
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
        _resets.resetShown();
    }
  }

  /// LIR-011: open as a nested webview using the chosen site's settings.
  /// LIR-015: a routed outbound link opens the same way over [source], the
  /// site it came from. The ordering is the activation table's
  /// ([SiteActivationController.openNested]).
  Future<void> _executeOpenNested(
    DispatchOpenNested a, {
    WebViewModel? source,
  }) async {
    final index =
        _sites.models.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) return;
    await _activation.openNested(
      _sites.models[index],
      opening: (
        screen: NestedOpenBinding(
          host: _PageHost(this),
          webspaces: _webspaces,
          fromTab: a.sourceIsParent && source != null,
        ),
        url: a.url,
        source: a.sourceIsParent ? source : null,
      ),
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
        posture: model.sitePosture(
          globalUserScripts: _shell.globalUserScripts,
          isolation: _sites.isolation,
        ),
        opensFromTab: opensFromTab,
        homeTitle: model.name,
      );

  /// The one way the set of sites changes ([SiteSetCommit]).
  Future<void> _commitSites(SiteSetChange change) => _commit.commit(change);

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
    return _sites.shown?.tabBarButtonCorner ??
        (AppPref.tabBarButtonOnRight.value
            ? TabBarCorner.bottomRight
            : TabBarCorner.bottomLeft);
  }

  void _openLinkHandlingSettings() {
    unawaited(Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => LinkHandlingSettingsScreen(
          sites: List<WebViewModel>.from(_sites.models),
          onOpenSiteEditor: (site) {
            if (_sites.models.contains(site)) {
              Navigator.of(ctx).pop();
              unawaited(_editing.editSite(site));
            }
          },
          onManualDispatch: (uri) async {
            await _links.dispatchInbound(InboundUrl(uri));
          },
        ),
      ),
    ));
  }

  late final DialogWebViewPrompts _prompts = DialogWebViewPrompts(context);

  /// What this page answers for every site webview, root and nested.
  late final WebViewHostHooks _webViewHooks = WebViewHostHooks(
    isolation: () => _sites.isolation,
    globalUserScripts: () => _shell.globalUserScripts,
    save: () => _commitSites(const SitesEdited()),
    rebuild: () {
      if (mounted) setState(() {});
    },
    onScreen: (slot) => identical(_sites.shown, slot),
    launchNested: launchUrl,
    openInBrowser: launchUrlInSystemBrowser,
    routeOutbound: _links.routeOutbound,
    // Identity, not index: the list can have been reordered by the time the
    // native event lands.
    linkMenu: (source, {required url}) =>
        unawaited(_showLinkLongPressMenu(source, url: url)),
    firstPageLoaded: (source, {required url}) =>
        unawaited(_editing.offerRedirectHome(source, url: url)),
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
    final owner = opensFromTab ? _sites.shown : null;
    final parentTabId = owner?.activeTabId;
    final openedFrom = owner?.runningIdentity.getDisplayName();
    final nestedSite = _sites.byId(posture.siteId);
    Future<void> Function()? handOff;
    final webView = NestedScreenWebView();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InAppWebViewScreen(
          webView: webView,
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
    await webView.quiet();
    if (handOff case final run? when mounted) await run();
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

  void _toastOpenedInNewTab(WebViewModel model, {required TabId tabId}) =>
      _toast(
        (loc) => loc.tabsOpenedInNewTab,
        action: (loc) => SnackBarAction(
          label: loc.tabsSwitchAction,
          // Sites may have moved or gone by the time this is tapped.
          onPressed: () => unawaited(_tabs.openTab(model, tabId: tabId)),
        ),
      );

  void _toggleFind() {
    setState(() {
      _isFindVisible = !_isFindVisible;
    });
  }

  WebViewController? getController() =>
      _sites.shown?.getController(_webViewHooks);

  /// User-driven full session wipe for a single site. Under containers the
  /// container's data goes in place (the fork's `clearContainerData`, made for
  /// a bound container) and the webview is rebuilt against it: the user
  /// expects a fresh page, and Android's per-webview HTTP cache is beyond the
  /// clear. On the shared jar the site's known cookies are deleted and the
  /// page reloads, the most that can be scoped to one site while localStorage,
  /// IndexedDB and service workers are app-wide. A delete the jar refuses
  /// fails the wipe with [CookieJarFailure], which the settings screen that
  /// asked reports.
  Future<void> _clearSiteData(WebViewModel model) async {
    if (!_sites.models.contains(model)) return;

    // Reroll the anti-fingerprinting seed so the post-wipe page can't be
    // re-identified via a stable fingerprint (window size, canvas, …) after
    // a data clear (ETP-022). The fresh nonce is baked into the shim when the
    // webview is rebuilt against the cleared container.
    model.rerollFingerprint();

    final isolation = _sites.isolation;
    switch (isolation) {
      case Containers(:final engine):
        await engine.clearForSite(model.containerKey);
        setState(() {
          model.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
          // LIR-023: a slot running as this site binds the cleared container.
          for (final other in _sites.models) {
            if (other.activeTab.hostSiteId == model.siteId) {
              other.disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
            }
          }
          // Until the new webview's first load reports its own.
          model.cookies = const [];
        });
      case SharedJar():
        // The snapshot names what to delete, and the jar's pre-delete
        // cleanup reads it, so it goes only with the cookies.
        await model.deleteCookies(isolation);
        // No container holds this site's HTTP cache, so it outlives the
        // cookies, and a cache-first load would serve the page from before
        // the clear.
        await clearEngineCache();
    }
    // Restorable residue the container/cookie wipes don't reach, both engines:
    // the saved `controller.saveState()` bytes are replayed on the next
    // activation, so a page that stashed an identifier in its URL via
    // history.pushState would be reloaded at that URL and read itself back —
    // defeating the fingerprint reroll above (ETP-022).
    _navStateDebouncer.cancel(model.siteId);
    await _stateStorage.removeStatesForSite(model.siteId);
    await _commitSites(const SitesEdited());
    if (!mounted) return;
    // A rebuilt webview loads afresh on its own.
    if (isolation is SharedJar) await _resets.refreshShown();
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
    if (_kioskLocked || !_tabs.enabledFor(_sites.shown) || _isShowingTabsSheet) {
      return;
    }
    _isShowingTabsSheet = true;
    try {
      await _dismissKeyboard();
      if (!mounted || !_tabs.enabledFor(_sites.shown)) return;
      await _presentTabsSheet();
    } finally {
      _isShowingTabsSheet = false;
    }
  }

  bool _isShowingTabsSheet = false;

  /// The tabs sheet of the site on screen, or with [scope] the library's tab
  /// tree (WEBSPACE-004): every tree the scope holds, with no site on screen,
  /// so a tab picked there opens its site on that tab.
  Future<void> _presentTabsSheet({WebspaceId? scope}) async {
    final shown = scope == null ? _sites.shown : null;
    final sites = scope == null ? _tabs.sheetSites() : _tabs.sheetSitesIn(scope);
    final at = sites.indexWhere((s) => identical(s.model, shown));
    if (scope == null ? at < 0 : sites.isEmpty) return;
    final loc = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => TabsSheet(
        sites: sites,
        currentIndex: at,
        title: scope == null
            ? null
            : _sites.webspaces
                    .where((w) => w.id == scope && !w.isAll)
                    .firstOrNull
                    ?.name ??
                loc.tabsAllSites,
        onOpenTab: (site, {required tabId}) =>
            unawaited(_throughCard(site, to: (
              show: () => _tabs.openTab(site, tabId: tabId),
              shown: () => identical(_sites.shown, site) && site.activeTabId == tabId,
            ))),
        onNewTab: (site) => unawaited(_tabs.newTab(site)),
        onWebSearch: shown == null ? null : () => unawaited(_links.webSearch()),
        onCloseTab: (site, {required tabId}) =>
            unawaited(_tabs.closeTab(site, tabId: tabId)),
        onCloseSubtree: (site, {required tabId}) =>
            unawaited(_tabs.closeTab(site, tabId: tabId, subtree: true)),
        onMoveTab: _tabs.moveTab,
        onMoveSite: shown != null && _webspaces.canReorderView ? _moveSiteInTabsSheet : null,
        wayBack: shown == null ? null : _tabs.wayBackFrom(shown),
      ),
    );
  }

  /// [to] puts [site] on screen; in Alternative design it runs behind the
  /// site's card, grown from the site's icon where the library shows it and
  /// faded in over the screen elsewhere, so every switch looks the same.
  Future<void> _throughCard(WebViewModel site, {required CardSwitch to}) async {
    final zoom = _folderLibraryEnabled ? _launchZoom.currentState : null;
    if (zoom == null || to.shown()) return to.show();
    await zoom.open(site,
        from: _sites.shown == null
            ? _libraryKey.currentState?.siteWell(site.siteId)
            : null,
        to: to);
  }

  Future<void> _showLibraryTabs(WebspaceId scope) async {
    if (_kioskLocked || _isShowingTabsSheet) return;
    _isShowingTabsSheet = true;
    try {
      await _presentTabsSheet(scope: scope);
    } finally {
      _isShowingTabsSheet = false;
    }
  }

  /// A site heading dropped on another in the Tabs sheet (TAB-016): the same
  /// reorder the drawer grid and the tab strip make. Returns the sheet's sites
  /// afresh, since reordering "All" renumbers them.
  List<TabsSheetSite>? _moveSiteInTabsSheet(SiteId siteId,
      {required SiteId ontoSiteId}) {
    if (_tabs.busy || !_webspaces.canReorderView) return null;
    final order = _sites.filteredIndices();
    int at(String id) => order.indexWhere((i) =>
        i >= 0 && i < _sites.models.length && _sites.models[i].siteId == id);
    final from = at(siteId);
    final to = at(ontoSiteId);
    if (from < 0 || to < 0 || from == to) return null;
    _webspaces.reorderSite(from, newListIndex: to);
    return _tabs.sheetSites();
  }

  /// A long press that landed on a link. In-domain links can become a tab of
  /// this site; anything else keeps today's behaviour, and the sheet says why
  /// rather than silently offering nothing. A site without tabs gets the sheet
  /// without its New tab row.
  Future<void> _showLinkLongPressMenu(WebViewModel model,
      {required String url}) async {
    if (_kioskLocked) return;
    if (!identical(model, _sites.shown)) return;
    final tabs = _tabs.enabledFor(model);
    // WebKit shows its own link menu, with Share, where the app shows none;
    // Android's WebView has none to fall back to.
    if (!tabs && hostIsIOS) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final identity = model.runningIdentity;
    final inDomain =
        getNormalizedDomain(url) == getNormalizedDomain(model.navigationHomeUrl);
    // A link into another of the user's sites becomes that site's tab, as a
    // tap would open it (LIR-032).
    final tabRoute = !tabs || inDomain
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
      newTab: !tabs
          ? null
          : (
              enabled: inDomain || tabRoute != null,
              note: (loc) => inDomain
                  ? null
                  : tabHost != null
                      ? loc.tabsRunsAs(tabHost.getDisplayName())
                      : tabRoute == null
                          ? loc.tabsLinkOutsideSite(uri.host)
                          : null,
            ),
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
          unawaited(_tabs.openLinkInNewTab(model, url: url,
              hostSiteId: active.hostSiteId,
              openerSiteId: active.openerSiteId,
              homeUrl: active.homeUrl));
        } else {
          unawaited(_tabs.openLinkInNewTab(model, url: url,
              hostSiteId: tabHost?.siteId,
              openerSiteId: identity.siteId,
              homeUrl: url));
        }
      case LinkMenuChoice.open:
        unawaited(_links.openLinkAsTapped(model, url: url));
      case LinkMenuChoice.copy:
        await Clipboard.setData(ClipboardData(text: url));
      case LinkMenuChoice.share:
        unawaited(SharePlus.instance.share(ShareParams(uri: uri)));
    }
  }

  /// The one way the theme changes: the app, its saved settings and the
  /// webview of every site without a theme of its own follow.
  Future<void> _applyThemeSettings(AppThemeSettings next) async {
    setState(() => _shell.theme = next);
    widget.onThemeSettingsChanged(next);
    await _shell.saveTheme();
    if (!mounted) return;
    final webViewTheme = next.themeMode.webViewTheme;
    for (final model in List.of(_sites.models)) {
      await model.setAppTheme(webViewTheme);
    }
  }

  Future<void> _openAppSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AppSettingsScreen(
          currentSettings: _shell.theme,
          externalTorRunsHere: externalTorRunsHere,
          proxyRouterRunsHere: ProxyRouterService.canRunHere(useContainers: _sites.useContainers),
          containersRunHere: _sites.useContainers,
          siteNames: _siteNames(),
          torSites: _network.torSites(),
          onSettingsChanged: _applyThemeSettings,
          onExportSettings: _backup.export,
          onImportSettings: _backup.import,
          onTrustUboHosts: _backup.trustUboHosts,
          onRestoreArchive: _archives.promptRestore,
          hasOpenArchives: _archives.anyOpen,
          onCloseAllArchives: () async {
            final closed = await _archives.closeAll();
            _toast((loc) =>
                closed ? loc.homeArchivesClosed : loc.homeArchiveFull);
          },
          onOpenLinkHandlingSettings: _openLinkHandlingSettings,
          homeShortcuts: hostIsAndroid ? _shortcuts : null,
          webSearchSites: [
            for (final m in _sites.models)
              if (!m.isArchiveTier &&
                  m.searchCapability?.kind == SearchKind.web)
                (
                  siteId: m.siteId,
                  name: m.getDisplayName(),
                  containerColor: _sites.useContainers ? m.drawnContainerColor : null,
                ),
          ],
          globalUserScripts: _shell.globalUserScripts,
          onGlobalUserScriptsChanged: (scripts) {
            _shell.globalUserScripts = scripts;
            unawaited(_shell.saveGlobalUserScripts());
            _resets.resetAll();
          },
          onOutboundProxyChanged: _resets.resetAll,
          siteProxies: () => [
            for (final m in _sites.models) m.proxySettings,
          ],
          onSavedProxiesChanged: () {
            _resets.resetAll();
            unawaited(_network.refreshRoutes());
          },
        ),
      ),
    );
    if (!mounted) return;
    await _commitSites(const SiteSettingsClosed());
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

  PreferredSizeWidget _buildAppBar() {
    final loc = AppLocalizations.of(context);
    final currentModel = _sites.shown;
    return CardHandle(
      onHold: currentModel == null || _kioskLocked || !_folderLibraryEnabled
          ? null
          : (at) => _launchZoom.currentState?.hold(currentModel,
              at: at, to: _library(currentModel), back: _siteOnScreen(currentModel)),
      child: AppBar(
      bottom: currentModel == null
          ? null
          : PageLoadBar(
              loading: currentModel.isLoading,
              progress: currentModel.loadingProgress,
            ),
      // KIOSK-002: no leading menu button when locked.
      automaticallyImplyLeading: !_kioskLocked && !_folderLibraryEnabled,
      leading: !_kioskLocked && _folderLibraryEnabled
          ? IconButton(
              icon: const Icon(Icons.apps_rounded),
              tooltip: loc.homeBackToWebspaces,
              onPressed: () => unawaited(_onSiteMenuAction(SiteMenuAction.backToWebspaces)),
            )
          : null,
      title: currentModel != null
          ? GestureDetector(
              onDoubleTap: _fullscreen.toggle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      currentModel.getDisplayName(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            )
          : _selectedWebspace == null ? Text(loc.homeNoWebspaceSelected) : WebspaceName(_selectedWebspace!),
      // KIOSK-002: no app-bar actions (download, settings) when locked.
      actions: _kioskLocked ? const <Widget>[] : [
        // Tab count for the site on screen. Present whenever a site is shown,
        // even at one tab, because it is also how a new tab is opened.
        if (currentModel != null && _tabs.enabledFor(currentModel))
          TabCountButton(
            count: currentModel.tabs.length,
            onPressed: () => unawaited(_showTabsSheet()),
          ),
        const DownloadButton(),
        // Protection report shield, badged with the week's block count.
        // Same visibility rule as the settings gear: the webspaces list is
        // the app's "home", which is where a protection summary belongs.
        if (currentModel == null)
          ProtectionShieldButton(onPressed: _openProtectionReport),
        if (currentModel == null)
          IconButton(
            icon: Icon(Icons.settings),
            tooltip: loc.homeAppSettingsTooltip,
            onPressed: _openAppSettings,
          ),
        if (currentModel != null && !AppPref.showTabStrip.value)
          _siteMenu(SiteMenuPlacement.appBar),
      ],
    ));
  }

  /// Whether the tab strip is on screen, at either edge. Out of fullscreen it
  /// follows the "Site Tab Strip" pref. In fullscreen the behavior is an
  /// independent choice: always visible, revealed on demand by the tab-bar
  /// button, or hidden.
  bool get _tabStripShown {
    // KIOSK-002: never show the tab strip in a locked session, in or out of
    // fullscreen — no switching away from the kiosk site.
    if (_kioskLocked || _sites.shown == null) return false;
    if (_sites.filteredIndices().isEmpty) return false;
    if (_fullscreen.active) {
      if (AppPref.tabStripInFullscreen.value) return true;
      return AppPref.tabBarButton.value && _fullscreen.tabStripRevealed;
    }
    return AppPref.showTabStrip.value || (AppPref.tabBarButton.value && _fullscreen.tabStripRevealed);
  }

  /// Whether the floating tab-bar button is currently shown. It reveals the
  /// tab strip (and its overflow menu) on demand, in and out of fullscreen.
  /// Suppressed while the strip is already pinned or revealed — the strip then
  /// carries its own dismiss control.
  bool get _tabBarButtonShown {
    if (!AppPref.tabBarButton.value) return false;
    // KIOSK-002: a locked session must not expose tab switching.
    if (_kioskLocked || _sites.shown == null) return false;
    if (_sites.filteredIndices().isEmpty) return false;
    if (_fullscreen.tabStripRevealed) return false;
    if (_fullscreen.active) return !AppPref.tabStripInFullscreen.value;
    return !AppPref.showTabStrip.value;
  }

  /// The edge the tab strip is on screen at, or null while it is not.
  TabStripEdge? get _tabStripEdge =>
      _tabStripShown ? TabStripEdge.current : null;

  /// The tab strip when it is on screen at [at]: the top of the body, or
  /// bottomNavigationBar, where it is hidden while the keyboard is open.
  Widget? _buildTabStrip({required TabStripEdge at}) {
    if (_tabStripEdge != at) return null;
    if (at == TabStripEdge.bottom &&
        MediaQuery.of(context).viewInsets.bottom > 0) {
      return null;
    }
    return SiteTabStrip(
      edge: at,
      models: _sites.models,
      order: _sites.filteredIndices(),
      current: _sites.current,
      revealed: _fullscreen.tabStripRevealed,
      onHide: _fullscreen.hideTabStrip,
      onOpen: _openSite,
      onShowTabs: () => unawaited(_showTabsSheet()),
      onReorder: _webspaces.canReorderView
          ? (from, {required to}) => _webspaces.reorderSite(from, newListIndex: to)
          : null,
      menu: _siteMenu(SiteMenuPlacement.tabStrip),
    );
  }

  /// Build the URL bar and find toolbar, placed in the body so that
  /// resizeToAvoidBottomInset keeps them above the keyboard.
  Widget? _buildInputBar() {
    final model = _sites.shown;
    if (_fullscreen.active || model == null) return null;
    final hasUrlBar = AppPref.showUrlBar.value;
    final hasFindToolbar = _isFindVisible && getController() != null;
    if (!hasUrlBar && !hasFindToolbar) {
      return null;
    }
    final urlBarSearch =
        hasUrlBar && !_kioskLocked ? _links.urlBarSearchFor(model) : null;

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
            key: _urlBar,
            currentUrl: model.currentUrl,
            searchSites: urlBarSearch?.sites ?? const [],
            defaultSearchSiteId: urlBarSearch?.defaultId,
            onSearch: urlBarSearch == null
                ? null
                : (query, {required siteId}) =>
                    _links.searchFromUrlBar(model, query: query, siteId: siteId),
            onSiteInfo: () => showSiteInfoFor(context,
                site: model, isolation: _sites.isolation),
            onUrlSubmitted: (url) => _links.openTypedAddress(model, url: url),
          ),
      ],
    );
  }

  SiteMenuButton _siteMenu(SiteMenuPlacement placement) => SiteMenuButton(
        placement: placement,
        state: () => (
          loading: _sites.shown?.isLoading ?? false,
          tabsOn: _tabs.enabledFor(_sites.shown),
          fullscreen: _fullscreen.active,
          offersShortcut: switch (_sites.shown) {
            final shown? => _shortcuts.offersShortcutFor(shown),
            null => false,
          },
        ),
        nav: (
          back: () => unawaited(_back.goBackIfPossible()),
          home: _resets.goHome,
          share: () {
            if (_sites.shown case final model?) {
              unawaited(SharePlus.instance
                  .share(ShareParams(uri: Uri.parse(model.currentUrl))));
            }
          },
          reload: () => unawaited(_resets.refreshShown()),
          stop: () => unawaited(_resets.stopShown()),
          backInNewTab: _tabs.forShownSite(_tabs.openBackInNewTab),
          duplicateTab: _tabs.forShownSite(_tabs.duplicateTab),
        ),
        onSelected: _onSiteMenuAction,
      );

  Future<void> _onSiteMenuAction(SiteMenuAction action) async {
    final model = _sites.shown;
    switch (action) {
      case SiteMenuAction.newTab:
        if (model != null) await _tabs.newTab(model);
      case SiteMenuAction.backToWebspaces:
        final zoom = _folderLibraryEnabled ? _launchZoom.currentState : null;
        if (model != null && zoom != null) {
          await zoom.close(model, to: _library(model));
        } else {
          await _toLibrary();
        }
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
        if (model != null) await _openSiteSettings(model);
      case SiteMenuAction.devTools:
        if (model == null) return;
        unawaited(Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DevToolsScreen(
              host: WebViewModelDevToolsHost(model),
              isolation: _sites.isolation,
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
      {required WebViewModel site, required Offset position}) async {
    if (!_sites.models.contains(site)) return;
    int listIndexOf() =>
        _sites.filteredIndices().indexOf(_sites.models.indexOf(site));
    final listIndex = listIndexOf();
    // Alternative design's icons move by dragging, as a launcher's do.
    final menuMoves = _webspaces.canReorderView && !_folderLibraryEnabled;
    final action = await showSiteListMenu(
      context,
      position: position,
      canMoveUp: menuMoves && listIndex > 0,
      canMoveDown: menuMoves &&
          listIndex >= 0 &&
          listIndex < _sites.filteredIndices().length - 1,
      archived: site.isArchiveTier,
    );
    if (!_sites.models.contains(site)) return;
    switch (action) {
      case null:
        return;
      case SiteListAction.moveToArchive:
        await _archives.moveIn(site);
      case SiteListAction.moveOutOfArchive:
        await _archives.moveOut(site);
      case SiteListAction.closeArchive:
        await _archives.closeArchiveOf(site);
      case SiteListAction.edit:
        await _editing.editSite(site);
      case SiteListAction.delete:
        await _editing.deleteSite(site);
      case SiteListAction.moveUp || SiteListAction.moveDown:
        final at = listIndexOf();
        if (at < 0) return;
        final to = action == SiteListAction.moveUp ? at - 1 : at + 1;
        if (to < 0 || to >= _sites.filteredIndices().length) return;
        _webspaces.reorderSite(at, newListIndex: to);
    }
  }

  /// The selected webspace, or null while none is selected.
  Webspace? get _selectedWebspace => _sites.webspaces
      .where((ws) => ws.id == _sites.selectedWebspaceId)
      .firstOrNull;

  /// Back to the webspaces: from the drawer, the grid button or a held card.
  Future<void> _toLibrary() async {
    await _activation.activate(null);
    if (!mounted) return;
    setState(() {});
    await _shell.saveSelectedWebspaceId();
    await _shell.saveCurrentIndex();
    if (mounted) _scaffoldKey.currentState?.closeDrawer();
  }

  /// The library [site]'s card returns to, landing in its icon there.
  CardLanding _library(WebViewModel site) => (
        show: _toLibrary,
        shown: () => _sites.shown == null,
        into: () => _libraryKey.currentState?.siteWell(site.siteId),
      );

  /// A site picked in the drawer, the library or the tab strip, once a
  /// webspace switch in flight lands.
  Future<void> _openSiteFromDrawer(WebViewModel site) async {
    // closeDrawer() (not Navigator.pop) is idempotent: a rapid second tap
    // won't pop the underlying page route once the drawer is already closing.
    _scaffoldKey.currentState?.closeDrawer();
    await _webspaces.switchInFlight;
    await _activation.activate(site);
    if (!mounted) return;
    setState(() {});
    await _shell.saveCurrentIndex();
  }

  /// A site picked in the tab strip or the library, or by its keyboard
  /// shortcut, shown behind its card.
  Future<void> _openSite(WebViewModel site) =>
      _throughCard(site, to: _siteOnScreen(site));

  CardSwitch _siteOnScreen(WebViewModel site) => (
        show: () => _openSiteFromDrawer(site),
        shown: () => identical(_sites.shown, site),
      );

  /// `siteId` -> display name for the sites the protection report may name.
  /// Archive-tier sites are excluded: they never contribute a count
  /// (STATS-005), so naming them there could only ever be noise.
  Map<String, String> _siteNames() => {
        for (final model in _sites.models)
          if (!model.isArchiveTier) model.siteId: model.getDisplayName(),
      };

  /// The page's hooks on a loaded site, set on every build; each reads the
  /// page's state when it fires.
  void _wireSite(WebViewModel site) {
    _surface.watch(site, onScreen: () => identical(site, _sites.shown));
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
    site.onReturnToOwner = site.effectiveTabsEnabled
        ? (url) => unawaited(_tabs.returnToOwner(site, url: url))
        : null;
  }

  /// Build the body with the input bar (URL bar / find toolbar) integrated,
  /// so resizeToAvoidBottomInset naturally keeps them above the keyboard.
  /// A top tab strip leads the body; a bottom one stays in
  /// bottomNavigationBar.
  Widget _buildBodyWithBottomBar() {
    _sites.loaded.forEach(_wireSite);
    final inputBar = _buildInputBar();
    final topStrip = _buildTabStrip(at: TabStripEdge.top);
    final nudgeInset = _surface.bottomInset;
    // A bottom tab strip (in bottomNavigationBar) handles the bottom safe
    // area when visible. Input bar has its own SafeArea. Only apply body safe
    // area when neither is present (e.g. webspace list screen). The tab strip
    // is also rendered when kept in fullscreen or temporarily revealed by the
    // tab-bar button, in which case it owns the safe-area inset of its edge.
    final hasBottomStrip = _tabStripEdge == TabStripEdge.bottom;
    return SafeArea(
      // Out of fullscreen the AppBar absorbs the top inset, so top stays false.
      // In fullscreen there is no AppBar, and the immersive modes do not
      // reliably hide the status/navigation bars on Android 15 (edge-to-edge
      // enforced) — when they remain, edge-to-edge content lands behind them
      // and the site's top/bottom controls become untappable. Inset the body on
      // both edges so it stays clear of any bars that persist, or that the user
      // revealed under `immersive` (FS-011); when they are truly hidden the
      // padding is ~0 and the webview still fills the screen. github #385
      // A tab strip along the top keeps the status bar, and this inset puts
      // the strip under it (FS-012).
      top: _fullscreen.active || (_folderLibraryEnabled && _sites.shown == null),
      bottom: !hasBottomStrip && inputBar == null,
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
          ?topStrip,
          // Keyed: the strip above and the input bar below come and go in
          // one frame (leaving full screen), and an unkeyed child between
          // them is remounted, taking the webviews with it.
          Expanded(
            key: const ValueKey('site-stack'),
            child: Stack(
              children: [
                Offstage(
                  offstage: _sites.shown != null,
                  child: _folderLibraryEnabled ? WebspaceLibrary(
                    key: _libraryKey,
                    webspaces: _sites.webspaces,
                    selectedWebspaceId: _sites.selectedWebspaceId,
                    sites: _sites.models,
                    currentSite: _sites.shown,
                    showsTabCount: _tabs.enabledFor,
                    onSelectWebspace: _webspaces.select,
                    onAddWebspace: _webspaces.add,
                    onEditWebspace: _webspaces.edit,
                    onDeleteWebspace: _webspaces.delete,
                    onReorder: _webspaces.reorder,
                    onOpenSite: (site) => unawaited(_openSite(site)),
                    onSiteMenu: _showSiteContextMenu,
                    onReorderSite: _webspaces.canReorderView
                        ? (from, {required to}) =>
                              _webspaces.reorderSite(from, newListIndex: to)
                        : null,
                    onAddSite: ({required into}) =>
                        unawaited(_editing.addSite(into: into)),
                    onShowTabs: (scope) => unawaited(_showLibraryTabs(scope)),
                    onOpenSettings: _openAppSettings,
                    accentColor: _shell.theme.accentColor,
                  ) : WebspacesListScreen(
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
                    offstage: _sites.shown == null,
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
                        loaded: _sites.loadedRows,
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
                      onTap: _fullscreen.revealTabStrip,
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
    final bool webviewIsVisible = _sites.shown != null;
    // From build, not from the paths that change the site on screen: the site
    // shown and the window flag then change in the same frame, and a new path
    // that moves _sites.current cannot skip it (SCREENBLOCK-002).
    unawaited(_screenCaptureGuard.apply(blocked: screenCaptureBlocked(
      appWide: AppPref.blockScreenshots.value,
      siteOnScreen: _sites.shown?.blockScreenshots,
    )));
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildMainTree(context, webviewIsVisible: webviewIsVisible),
        if (_folderLibraryEnabled) LaunchZoom(key: _launchZoom, sites: _sites.models),
        // Snapshot-time mask: an opaque surface overlays everything so the
        // task-switcher / recents preview never captures archive content
        // (ARCH-009). Only the painted output is replaced.
        if (_maskBackground)
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
        // An open folder is Back's to close first, as on a phone's home
        // screen; only then does Back leave the library.
        if (!webviewIsVisible &&
            (_libraryKey.currentState?.closeFolder() ?? false)) {
          return;
        }
        await _back.handle();
      },
      child: Scaffold(
      key: _scaffoldKey,
      // Clearing on close covers every way the drawer goes away; a drawer
      // opened by any other affordance therefore starts with the flag down.
      onDrawerChanged: (isOpen) {
        _back.drawerChanged(open: isOpen);
      },
      // Disable the drawer edge-swipe whenever a webview is active so the back
      // gesture never opens the drawer. The drawer is reached via the AppBar
      // menu button instead.
      drawerEdgeDragWidth: _folderLibraryEnabled || webviewIsVisible ? 0 : null,
      appBar: _fullscreen.active || (_folderLibraryEnabled && !webviewIsVisible)
          ? null : _buildAppBar(),
      // KIOSK-002: a locked shell exposes neither navigation surface.
      drawer: _kioskLocked || _folderLibraryEnabled ? null : SiteDrawer(
        accentColor: _shell.theme.accentColor,
        webspace: _selectedWebspace,
        models: _sites.models,
        order: _sites.filteredIndices(),
        current: _sites.current,
        showsTabCount: _tabs.enabledFor,
        onBackToWebspaces: () => unawaited(_toLibrary()),
        onOpen: (site) => unawaited(_openSiteFromDrawer(site)),
        onMenu: _showSiteContextMenu,
        onReorder: _webspaces.canReorderView
            ? (from, {required to}) => _webspaces.reorderSite(from, newListIndex: to)
            : null,
        onAddSite: () => unawaited(_editing.addSite()),
      ),
      body: _buildBodyWithBottomBar(),
      floatingActionButton: _folderLibraryEnabled || webviewIsVisible ? null
          : FloatingActionButton(
              onPressed: () => unawaited(_editing.addSite()),
              child: Icon(Icons.add),
            ),
      bottomNavigationBar: _buildTabStrip(at: TabStripEdge.bottom),
    ),
    );
  }
}

class _ResidencyHost implements ResidencyHost {
  const _ResidencyHost(this.state);

  final _WebSpacePageState state;

  @override
  ResidencyCaps get caps => kResidencyCaps;

  @override
  List<WebViewModel> get models => state._sites.models;

  @override
  RuntimeVars<WebViewModel> get vars => state._sites.vars;

  @override
  Isolation get isolation => state._sites.isolation;

  @override
  NavCapture? beginNavCapture(WebViewModel model) =>
      state._activation.beginNavCapture(model);

  @override
  void noteUnloaded(WebViewModel model, {required UnloadReason reason}) =>
      state._background.noteUnloaded(model, reason: reason.label);

  @override
  List<WebViewModel> identities() => state._sites.slotIdentities();

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
        SiteEditingHost,
        BackGestureHost,
        SiteResetHost,
        NestedLaunchHost,
        StartupHost,
        SiteSetCommitHost,
        SiteDeletionHost,
        KeyboardShortcutHost {
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
  SiteSetStage stageSites(SiteSetChange change) => _s._commit.stage(change);

  @override
  Future<void> closeArchives() async {
    await _s._archives.closeAll();
  }

  @override
  Future<void> recordInArchive(SiteArchived change) =>
      _s._archives.recordIn(change.site, into: change.into);

  @override
  void pruneLinkReferences() {
    _s._links.pruneOutboundPreferences();
    _s._links.pruneSearchReferences();
  }

  @override
  Future<void> reconcileLinkTabs() => _s._tabs.reconcileLinkTabs();

  @override
  Future<void> closeIneligibleHostedTabs() =>
      _s._tabs.closeIneligibleHostedTabs();

  @override
  void screenEmptied() => _s._fullscreen.exit();

  @override
  Future<void> saveSelectedWebspaceId() => _s._shell.saveSelectedWebspaceId();

  @override
  Future<void> syncTorHolders() => _s._network.syncTorHolders();

  @override
  Future<void> persistSites() => _s._persistSites();

  @override
  Future<void> saveWebspaces() => _s._shell.saveWebspaces();

  @override
  Future<void> sweepOrphans() => _s._sweep.afterRemoval();

  @override
  Future<void> endOfFrame() => WidgetsBinding.instance.endOfFrame;

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async {
    // The shared jar holds whichever site was restored last; the snapshot is
    // this site's.
    if (_s._sites.isolation case final Containers containers) {
      try {
        final fresh = await containers.cookiesAt(
          Uri.parse(
            model.currentUrl.isNotEmpty ? model.currentUrl : model.initUrl,
          ),
          controller: model.controller,
        );
        if (fresh.isNotEmpty) return fresh;
      } on CookieJarFailure catch (e) {
        // The site's own list crosses instead: a read that failed is not an
        // empty jar (CONT-009).
        LogTag.containerCookieManager.warning(
            'Archive move read of "${model.name}" failed: $e',
            sensitive: true);
      }
    }
    return List<Cookie>.from(model.cookies);
  }

  @override
  bool get kioskLocked => _s._kioskLocked;

  @override
  set kioskLocked(bool locked) => _s._kioskLocked = locked;

  @override
  TabStripEdge? get tabStripEdge => _s._tabStripEdge;

  @override
  void resetForEntry() {
    Navigator.of(_s.context).popUntil((route) => route.isFirst);
    _s._fullscreen.hideTabStrip();
  }

  @override
  Future<void> activate(WebViewModel? site) => _s._activation.activate(site);

  @override
  ScaffoldState? get scaffold => _s._scaffoldKey.currentState;

  @override
  WebViewController? get shownController => _s.getController();

  @override
  Future<bool> backAtTabStart() => _s._tabs.backAtTabStart();

  @override
  CookieIsolationEngine get legacyJar => _s._cookieIsolation;

  @override
  Future<void> activateRouter() => _s._network.activateRouter();

  @override
  void closeDrawer() => _s._scaffoldKey.currentState?.closeDrawer();

  @override
  void openDrawer() {
    if (_s._folderLibraryEnabled && _s._sites.shown == null) {
      _s._libraryKey.currentState?.openFolder();
    } else {
      unawaited(openNavigationMenu());
    }
  }

  @override
  Future<void> openNavigationMenu() async {
    if (_s._folderLibraryEnabled) {
      await _s._onSiteMenuAction(SiteMenuAction.backToWebspaces);
    } else {
      _s._scaffoldKey.currentState?.openDrawer();
    }
  }

  @override
  void themeChanged() => _s.widget.onThemeSettingsChanged(_s._shell.theme);

  @override
  void syncTorExitPin(Iterable<WebViewModel> sites) =>
      _s._network.syncTorExitPin(sites);

  @override
  bool routeFree(WebViewModel site) => _s._activation.routeFreeFor(site);

  @override
  bool get nestedOpening => _s._activation.opensNested;

  @override
  void forgetTabReturns() => _s._tabs.forgetReturns();

  @override
  void exitFullscreen() => _s._fullscreen.exit();

  @override
  Future<void> refreshRoutes({WebViewModel? active}) =>
      _s._network.refreshRoutes(active: active);

  @override
  Future<bool> isOnline() => ConnectivityService.instance.isOnline();

  @override
  Future<void> spawned(Future<void> Function() flow) => flow();

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
  NavCapture? beginNavCapture(WebViewModel model) =>
      _s._activation.beginNavCapture(model);

  @override
  Future<bool> captureNavState(WebViewModel model) =>
      _s._activation.captureStateBytes(model);

  @override
  Future<void> handleShareIntent({required Reached<Launched> after}) =>
      _s._links.handleShareIntent(after: after);

  @override
  Future<Reached<Launched>?> launched() => _s._startup.launched();

  @override
  Future<void> resetHomeOnLaunch(WebViewModel launched) =>
      _s._resets.resetHomeOnLaunch(launched);

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
  Future<void> unloadSite(WebViewModel site, {required UnloadReason reason}) =>
      _s._activation.unload(site, reason: reason);

  @override
  Future<void> wipeContainer(ContainerKey key) async {
    if (_s._sites.isolation case Containers(:final engine)) {
      await engine.clearForSite(key);
    }
  }

  @override
  ArchiveHandle? archiveOf(WebViewModel model) =>
      _s._archives.archiveOf(model);

  @override
  void cancelPendingCapture(SiteId siteId) =>
      _s._navStateDebouncer.cancel(siteId);

  @override
  Future<void> saveCurrentIndex() => _s._shell.saveCurrentIndex();

  @override
  Future<void> saveSelectedWebspace() => _s._shell.saveSelectedWebspaceId();

  @override
  Future<void> revealSite(WebViewModel model) =>
      _s._webspaces.revealSite(model);

  @override
  void offerOpenTab(WebViewModel model, {required TabId tabId}) =>
      _s._toastOpenedInNewTab(model, tabId: tabId);

  @override
  List<DispatchableSite> tabHostsIn(WebViewModel owner,
          {required WebViewModel opener}) =>
      _s._links.tabHostsIn(owner, source: opener);

  @override
  void noteUnloaded(WebViewModel model, {required String why}) =>
      _s._background.noteUnloaded(model, reason: why);

  @override
  bool get onTop => ModalRoute.isCurrentOf(_s.context) ?? true;

  @override
  bool focusUrlBar() {
    final bar = _s._urlBar.currentState;
    bar?.edit();
    return bar != null;
  }

  @override
  bool findInPage() {
    // The input bar, the find bar's place, is gone in full screen.
    if (_s._fullscreen.active) return false;
    _s._toggleFind();
    return true;
  }

  @override
  Future<void> openSite(WebViewModel site) => _s._openSite(site);
}
