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

  /// Which navigation surfaces show, decided once by the engine.
  NavigationSurfaces get _surfaces => navigationSurfaces((
        navigation: currentSiteNavigation,
        inFullscreen: currentFullscreenNavigation,
        fullscreen: _fullscreen.active,
        sidebar: currentSidebarState,
        wide: _wideNavigation,
        kioskLocked: _kioskLocked,
        siteOnScreen: _sites.shown != null && _sites.filteredIndices().isNotEmpty,
        revealed: _fullscreen.siteStripRevealed,
      ));

  /// Whether the site strip is on screen, at either edge (KIOSK-002: never
  /// in a locked session).
  bool get _siteStripShown => _surfaces.strip;

  /// Whether the strip's floating button is shown: in full screen set to
  /// Button, until it reveals the strip, which then carries its own dismiss
  /// control.
  bool get _tabBarButtonShown => _surfaces.stripButton;

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
    _stripFollows(_sites.shown);
    return SiteStrip(
      edge: at,
      models: _sites.models,
      order: _sites.filteredIndices(),
      current: _sites.current,
      revealed: _fullscreen.siteStripRevealed,
      onHide: _fullscreen.hideSiteStrip,
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
}
