part of 'webspace_page.dart';

/// How the page reaches its sites and their tabs: the Tabs sheet, the site
/// strip and the sidebar, as the navigation surface engine decides.
extension _PageNavigation on _WebSpacePageState {
  Future<void> _showTabsSheet() async {
    if (_kioskLocked || !_tabs.enabledFor(_sites.shown) || _isShowingTabsSheet) {
      return;
    }
    _isShowingTabsSheet = true;
    try {
      await _presentTabsSheet();
    } finally {
      _isShowingTabsSheet = false;
    }
  }

  /// The tabs sheet of the site on screen, or with [scope] the library's tab
  /// tree (WEBSPACE-004): every tree the scope holds, with no site on screen,
  /// so a tab picked there opens its site on that tab.
  Future<void> _presentTabsSheet({WebspaceId? scope}) async {
    final shown = scope == null ? _sites.shown : null;
    final (:sites, :wayBack) = _tabs.sheetListing(scope: scope);
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
            _tabs.closeFromSheet(site, tabId: tabId, subtree: false, scope: scope),
        onCloseSubtree: (site, {required tabId}) =>
            _tabs.closeFromSheet(site, tabId: tabId, subtree: true, scope: scope),
        onReopen: (closed) => _tabs.reopenFromSheet(closed, scope: scope),
        onMoveTab: _tabs.moveTab,
        onMoveSite: shown != null && _webspaces.canReorderView ? _moveSiteInTabsSheet : null,
        wayBack: wayBack,
      ),
    );
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
  /// reorder the drawer grid and the site strip make. Returns the sheet's sites
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

  /// Whether the window is wide enough to dock the sidebar beside the page.
  bool get _wideNavigation => isWideNavigation(MediaQuery.sizeOf(context).width);

  /// Whether a narrow window docks the rail here.
  bool get _narrowRail => railOnNarrow(screenEdgeBack: hostIsIOS);

  /// Which navigation surfaces show, decided once by the engine.
  NavigationSurfaces get _surfaces => navigationSurfaces((
        navigation: currentSiteNavigation,
        inFullscreen: currentFullscreenNavigation,
        fullscreen: _fullscreen.active,
        sidebar: currentSidebarState,
        drawerShown: _sidebar.drawerShown,
        wide: _wideNavigation,
        kioskLocked: _kioskLocked,
        siteOnScreen: _sites.shown != null && _sites.filteredIndices().isNotEmpty,
        legacyWebspace: !_libraryDesign && _selectedWebspace != null,
        revealed: _fullscreen.navigationRevealed,
        narrowRail: _narrowRail,
        stripHidden: AppPref.siteStripHidden.value,
        legacyDesign: !_libraryDesign,
      ));

  /// Whether the site strip is on screen, at either edge (KIOSK-002: never
  /// in a locked session).
  bool get _siteStripShown => _surfaces.strip;

  /// Whether the strip's floating button is shown: in full screen set to
  /// Button, until it reveals the strip, which then carries its own dismiss
  /// control.
  bool get _tabBarButtonShown => _surfaces.stripButton;

  /// The strip's close control: in full screen the button's reveal ends,
  /// otherwise the strip stays hidden behind its button (TAB-038).
  void _hideStrip() {
    if (_fullscreen.active) {
      _fullscreen.hideNavigation();
    } else {
      unawaited(AppPref.siteStripHidden.set(true));
    }
  }

  /// The arrow tab let go on the page: the strip in use, hidden behind its
  /// button at [corner] (TAB-038).
  void _stripButtonAt(TabBarCorner corner) {
    final site = _sites.shown;
    if (site != null && site.tabBarButtonCorner != corner) {
      site.tabBarButtonCorner = corner;
      unawaited(_commitSites(const SitesEdited()));
    }
    unawaited(useSiteNavigation(SiteNavigation.strip, hidden: true));
  }

  /// The strip's button let go on the left edge, [fraction] down it: the
  /// sidebar in use, hidden behind its arrow tab there (TAB-038).
  void _sidebarArrowAt(double fraction) {
    unawaited(AppPref.sidebarHandleY.set((fraction.clamp(0.1, 0.9) * 100).round()));
    unawaited(useSiteNavigation(SiteNavigation.sidebar, hidden: true));
  }

  /// The strip's button: the strip back, over the page in full screen.
  void _showStrip() {
    if (_fullscreen.active) {
      _fullscreen.revealNavigation();
    } else {
      unawaited(AppPref.siteStripHidden.set(false));
    }
  }

  /// The edge the site strip is on screen at, or null while it is not.
  SiteStripEdge? get _siteStripEdge =>
      _siteStripShown ? SiteStripEdge.current : null;

  /// The site strip when it is on screen at [at]: the top of the body, or
  /// bottomNavigationBar, where it is hidden while the keyboard is open.
  Widget? _buildSiteStrip({required SiteStripEdge at}) {
    if (_siteStripEdge != at) return null;
    if (at == SiteStripEdge.bottom &&
        MediaQuery.of(context).viewInsets.bottom > 0) {
      return null;
    }
    return SiteStrip(
      edge: at,
      models: _sites.models,
      order: _sites.filteredIndices(),
      current: _sites.current,
      hideable: !_fullscreen.active || _fullscreen.navigationRevealed,
      onHide: _hideStrip,
      onOpen: _openSite,
      onShowTabs: _toggleStripSite,
      open: _openSites,
      onToggleOpen: (id) {
        _openSites = _openSites.toggle(id,
            current: _sites.shown?.siteId, single: !_wideNavigation);
        _rebuild();
      },
      tabs: _tabChipActions,
      onReorder: _webspaces.canReorderView
          ? (from, {required to}) => _webspaces.reorderSite(from, newListIndex: to)
          : null,
      menu: _siteMenu(SiteMenuPlacement.tabStrip),
    );
  }


  /// A tap on the chip of the site on screen: its tabs open or close.
  void _toggleStripSite() {
    final shown = _sites.shown;
    if (shown == null || !_tabs.enabledFor(shown)) return;
    _openSites = _openSites.toggle(shown.siteId,
        current: shown.siteId, single: !_wideNavigation);
    _rebuild();
  }

  /// [_openSites] once [site] has come on screen: its tabs open, and on a
  /// phone the others close.
  void _stripFollows(WebViewModel? site) {
    if (site == null || site.siteId == _openSitesFor) return;
    _openSitesFor = site.siteId;
    _openSites = _openSites.onSwitch(to: site.siteId, single: !_wideNavigation);
  }

  /// What a tab chip in the strip or the squares asks: through the tabs
  /// controller, as the Tabs sheet asks it, a close offering its undo.
  TabChipActions get _tabChipActions => (
        open: (site, {required tabId}) => unawaited(_throughCard(site, to: (
              show: () => _tabs.openTab(site, tabId: tabId),
              shown: () =>
                  identical(_sites.shown, site) && site.activeTabId == tabId,
            ))),
        close: (site, {required tabId}) => unawaited(_closeChip(site, tabId: tabId)),
        add: (site) => unawaited(_tabs.newTab(site)),
      );

  Future<void> _closeChip(WebViewModel site, {required TabId tabId}) async {
    final messenger = ScaffoldMessenger.of(context);
    final loc = AppLocalizations.of(context);
    final title = site.tabs.where((t) => t.id == tabId).firstOrNull?.title;
    final (:listing, :kept) =
        await _tabs.closeFromSheet(site, tabId: tabId, subtree: false);
    if (!mounted) return;
    _rebuild();
    if (kept == null) return;
    messenger.toast(
      loc.tabsClosedNamed(title ?? addressOf(site.initUrl, loc: loc)),
      replace: true,
      action: SnackBarAction(
        label: loc.tabsUndoClose,
        onPressed: () => unawaited(
            _tabs.reopenFromSheet(kept).then((_) => _rebuild())),
      ),
    );
  }

  /// Whether the sidebar takes the legacy drawer's place (TAB-036).
  bool get _sidebarChosen => sidebarReplacesDrawer(
        libraryDesign: _libraryDesign,
        navigation: currentSiteNavigation,
        sidebar: currentSidebarState,
      );

  /// Rail widths: a phone's rail is narrower.
  double get _railWidth => _wideNavigation ? 60 : 52;

  /// The width of the sidebar over the page: the phone's drawer, or the
  /// full-screen sidebar.
  double get _floatWidth =>
      _wideNavigation ? AppPref.sidebarWidth.value.toDouble() : 290;

  /// Whether the arrow tab reveals the sidebar over the page, full screen
  /// being set to Button.
  bool get _revealsOverlay =>
      _fullscreen.active &&
      currentFullscreenNavigation == FullscreenNavigation.button;

  /// The app bar's leading button: the Alternative design's way back to the
  /// webspaces. A hidden sidebar comes back by its arrow tab alone.
  Widget? _appBarLeading(AppLocalizations loc) {
    if (_kioskLocked || !_libraryDesign) return null;
    return IconButton(
      icon: const Icon(Icons.apps_rounded),
      tooltip: loc.homeBackToWebspaces,
      onPressed: () =>
          unawaited(_onSiteMenuAction(SiteMenuAction.backToWebspaces)),
    );
  }

  /// The page laid out with its sidebar.
  Widget _navigationFrame(Widget main) {
    _stripFollows(_sites.shown);
    final surfaces = _surfaces;
    // The phone's sidebar drawer closing is a drawer closing to the back
    // gesture, as the Scaffold's reports its own.
    final drawer = surfaces.float == SidebarFloat.drawer;
    if (_wasDrawer != drawer) _back.drawerChanged(open: drawer);
    _wasDrawer = drawer;
    return SiteNavigationFrame(
      key: _frame,
      surfaces: surfaces,
      main: main,
      panelWidth: AppPref.sidebarWidth.value.toDouble(),
      floatWidth: _floatWidth,
      railWidth: _railWidth,
      panel: (width, {required floating}) =>
          _sidebarPanel(width, floating: floating),
      rail: _sidebarRail(),
      handleFraction: AppPref.sidebarHandleY.value / 100,
      revealsOverlay: _revealsOverlay,
      expandsOnHover: AppPref.sidebarExpandOnHover.value,
      onArrowTap: () =>
          _revealsOverlay
              ? _fullscreen.revealNavigation()
              : _sidebar.restore(drawer: !_wideNavigation && !_narrowRail),
      onSettle: (to) => _sidebar.settle(to, wide: _wideNavigation),
      onReveal: (shown) =>
          shown ? _fullscreen.revealNavigation() : _fullscreen.hideNavigation(),
      onDismissFloat: _putFloatAway,
      edgeBack: edgeSwipeGoesBack(
        screenEdgeBack: hostIsIOS,
        dock: surfaces.dock,
      )
          ? EdgeBack(
              canGoBack: () async => await getController()?.canGoBack() ?? false,
              goBack: () => unawaited(getController()?.goBack()),
            )
          : null,
      onHandleMoved: (fraction) =>
          unawaited(AppPref.sidebarHandleY.set((fraction * 100).round())),
      onLiftedOff: (at) => _stripButtonAt(
        tabBarCornerNearest(at.x, y: at.y),
      ),
      onResize: (width) => unawaited(AppPref.sidebarWidth.set(width.round())),
    );
  }

  /// A sidebar over the page goes: the full-screen one is put away, the
  /// phone's drawer leaves the rail.
  void _putFloatAway() {
    if (_revealsOverlay) {
      _fullscreen.hideNavigation();
    } else {
      _sidebar.closeDrawer();
    }
  }

  List<WebViewModel> get _webspaceSites =>
      [for (final i in _sites.filteredIndices()) _sites.models[i]];

  /// The open sidebar: the squares or the tab tree, under its title row.
  Widget _sidebarPanel(double width, {required bool floating}) {
    final loc = AppLocalizations.of(context);
    final shown = _sites.shown;
    final actions = _tabChipActions;
    void picked() {
      if (floating) _putFloatAway();
    }
    final Widget body = switch (currentSidebarStyle) {
      SidebarStyle.squares => SidebarSquares(
          sites: _webspaceSites,
          current: shown,
          open: _openSites,
          onSquare: (site) {
            if (identical(site, shown)) return _toggleStripSite();
            unawaited(_openSite(site));
            picked();
          },
          onToggleOpen: (site) {
            _openSites = _openSites.toggle(site.siteId,
                current: shown?.siteId, single: !_wideNavigation);
            _rebuild();
          },
          actions: (
            open: (site, {required tabId}) {
              actions.open(site, tabId: tabId);
              picked();
            },
            close: actions.close,
            add: actions.add,
          ),
          onMenu: _showSiteContextMenu,
        ),
      SidebarStyle.tree => _sidebarTree(floating: floating, picked: picked),
    };
    // The legacy design's sidebar is its drawer: its header and Add Site.
    final legacy = !_libraryDesign;
    return SiteSidebar(
      width: width,
      title: legacy
          ? SiteDrawerHeader(
              accentColor: _shell.theme.accentColor,
              webspace: _selectedWebspace,
              onBackToWebspaces: () => unawaited(_toLibrary()),
            )
          : Text(
              _selectedWebspace?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
      body: body,
      view: (
        style: currentSidebarStyle,
        onChanged: (style) => unawaited(AppPref.sidebarStyle.set(style.name)),
      ),
      footer: legacy
          ? AddSiteButton(onAddSite: () => unawaited(_editing.addSite()))
          : null,
      onCollapse: floating ? _putFloatAway : _sidebar.collapse,
      collapseTooltip: floating ? loc.sidebarPutAway : loc.sidebarCollapse,
      onResize: floating ? null : (dx) => _frame.currentState?.resizeBy(dx),
      onResizeEnd: floating ? null : () => _frame.currentState?.resizeEnd(),
    );
  }

  Widget _sidebarTree({required bool floating, required VoidCallback picked}) {
    final (:sites, :wayBack) = _tabs.sidebarListing();
    final at = sites.indexWhere((s) => identical(s.model, _sites.shown));
    Future<TabsSheetClosed> close(WebViewModel site,
        {required TabId tabId, required bool subtree}) async {
      final (:listing, :kept) =
          await _tabs.closeFromSheet(site, tabId: tabId, subtree: subtree);
      _rebuild();
      return (listing: _tabs.sidebarListing(), kept: kept);
    }
    return TabsSheet(
      host: floating && !_wideNavigation
          ? TabsSheetHost.drawer
          : TabsSheetHost.sidebar,
      sites: sites,
      currentIndex: at,
      title: at < 0 ? (_selectedWebspace?.name ?? '') : null,
      onOpenTab: (site, {required tabId}) {
        _tabChipActions.open(site, tabId: tabId);
        picked();
      },
      onNewTab: (site) => unawaited(_tabs.newTab(site)),
      onCloseTab: (site, {required tabId}) =>
          close(site, tabId: tabId, subtree: false),
      onCloseSubtree: (site, {required tabId}) =>
          close(site, tabId: tabId, subtree: true),
      onReopen: (closed) async {
        await _tabs.reopenFromSheet(closed);
        _rebuild();
        return _tabs.sidebarListing();
      },
      onMoveTab: _tabs.moveTab,
      onMoveSite: _webspaces.canReorderView ? _moveSiteInTabsSheet : null,
      wayBack: wayBack,
    );
  }

  Widget _sidebarRail() => SidebarRail(
        sites: _webspaceSites,
        current: _sites.shown,
        width: _railWidth,
        onOpen: (site) => unawaited(_openSite(site)),
        onOpenTab: (site, {required tabId}) =>
            _tabChipActions.open(site, tabId: tabId),
        onExpand: () => _sidebar.expand(wide: _wideNavigation),
        onHide: _sidebar.hide,
      );
}
