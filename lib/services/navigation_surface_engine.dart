import 'package:webspace/settings/navigation_choices.dart';

/// What the page knows when it decides which navigation surfaces show.
typedef NavigationQuery = ({
  SiteNavigation navigation,
  FullscreenNavigation inFullscreen,
  bool fullscreen,
  SidebarState sidebar,
  // A phone's drawer is open over the page.
  bool drawerShown,
  bool wide,
  bool kioskLocked,
  bool siteOnScreen,
  // The legacy design has a webspace picked, whose sites its sidebar lists
  // as its drawer did, with a site on screen or not.
  bool legacyWebspace,
  // The full-screen control has shown its strip or sidebar.
  bool revealed,
  // A narrow window docks the rail ([railOnNarrow]).
  bool narrowRail,
  // The site strip is hidden behind its button (TAB-038).
  bool stripHidden,
  // The legacy design, whose hidden sidebar is its drawer (TAB-036).
  bool legacyDesign,
});

/// Whether full screen shows a floating control (the strip's button or the
/// sidebar's arrow tab), so the system bars stay revealable rather than
/// sticky, as they are with nothing of the app's on screen.
bool floatsInFullscreen({required FullscreenNavigation inFullscreen}) =>
    inFullscreen == FullscreenNavigation.button;

/// Whether the sidebar takes the legacy design's drawer's place: in use and
/// not hidden, for in the legacy design a hidden sidebar is its drawer
/// (TAB-036). The library design has no drawer.
bool sidebarReplacesDrawer({
  required bool libraryDesign,
  required SiteNavigation navigation,
  required SidebarState sidebar,
}) =>
    navigation == SiteNavigation.sidebar &&
    (libraryDesign || sidebar != SidebarState.hidden);

/// What the site menu offers to switch to (TAB-038).
typedef MenuOffers = ({bool sidebar, bool strip});

/// The navigation not on screen: the other one, and from the legacy
/// design's drawer, which stands for a hidden sidebar, the sidebar too.
MenuOffers menuOffers({
  required SiteNavigation navigation,
  required SidebarState sidebar,
  required bool legacyDesign,
}) =>
    switch (navigation) {
      SiteNavigation.strip => (sidebar: true, strip: false),
      SiteNavigation.sidebar => (
          sidebar: legacyDesign && sidebar == SidebarState.hidden,
          strip: true,
        ),
    };

/// Whether a narrow window docks the rail beside the page: not where the
/// webview's back swipe answers only at the screen's edge ([screenEdgeBack],
/// iOS), which a docked rail would take from it (TAB-033). There the arrow
/// tab stands for the rail.
bool railOnNarrow({required bool screenEdgeBack}) => !screenEdgeBack;

/// Whether a window this wide docks the sidebar beside the page; a
/// narrower one is a phone's, where open is a drawer over the page (the
/// width Material's expanded windows start at).
bool isWideNavigation(double width) => width >= 840;

/// What the sidebar docks beside the page.
enum SidebarDock { none, rail, full }

/// What the sidebar floats over the page: the phone's drawer, or the
/// full-screen sidebar a control revealed.
enum SidebarFloat { none, drawer, overlay }

/// Every navigation surface, on or off.
typedef NavigationSurfaces = ({
  bool strip,
  SidebarDock dock,
  SidebarFloat float,
  bool arrowTab,
  bool tabCountButton,
  bool stripButton,
});

const NavigationSurfaces _none = (
  strip: false,
  dock: SidebarDock.none,
  float: SidebarFloat.none,
  arrowTab: false,
  tabCountButton: false,
  stripButton: false,
);

/// The one decision of which navigation surfaces show (the site navigation
/// design's tables): a locked kiosk and a page with no site on screen show
/// none, but for the legacy design's sidebar; otherwise the chosen
/// navigation, as full screen leaves it.
NavigationSurfaces navigationSurfaces(NavigationQuery q) {
  if (q.kioskLocked) return _none;
  if (!q.siteOnScreen &&
      !(q.legacyWebspace && q.navigation == SiteNavigation.sidebar)) {
    return _none;
  }
  return switch (q.navigation) {
    SiteNavigation.strip => _strip(q),
    SiteNavigation.sidebar => _sidebar(q),
  };
}

/// The strip docked at its edge, or hidden behind its button; in full
/// screen, by the user's switch, its button until it reveals the strip, or
/// nothing.
NavigationSurfaces _strip(NavigationQuery q) {
  final (strip, button) = !q.fullscreen
      ? (!q.stripHidden, q.stripHidden)
      : switch (q.inFullscreen) {
          FullscreenNavigation.button => (q.revealed, !q.revealed),
          FullscreenNavigation.hidden => (false, false),
        };
  return (
    strip: strip,
    dock: SidebarDock.none,
    float: SidebarFloat.none,
    arrowTab: false,
    tabCountButton: !q.fullscreen,
    stripButton: button,
  );
}

NavigationSurfaces _sidebar(NavigationQuery q) {
  if (q.fullscreen) {
    return switch (q.inFullscreen) {
      FullscreenNavigation.hidden => _none,
      FullscreenNavigation.button => (
          strip: false,
          dock: SidebarDock.none,
          float: !q.revealed
              ? SidebarFloat.none
              : (q.wide ? SidebarFloat.overlay : SidebarFloat.drawer),
          arrowTab: !q.revealed,
          tabCountButton: false,
          stripButton: false,
        ),
    };
  }
  if (q.legacyDesign && q.sidebar == SidebarState.hidden) {
    return (
      strip: false,
      dock: SidebarDock.none,
      float: SidebarFloat.none,
      arrowTab: false,
      tabCountButton: true,
      stripButton: false,
    );
  }
  if (!q.wide && !q.narrowRail) {
    return (
      strip: false,
      dock: SidebarDock.none,
      float: q.drawerShown ? SidebarFloat.drawer : SidebarFloat.none,
      arrowTab: !q.drawerShown,
      tabCountButton: true,
      stripButton: false,
    );
  }
  final (dock, float) = switch ((q.sidebar, q.wide)) {
    (SidebarState.open, true) => (SidebarDock.full, SidebarFloat.none),
    (SidebarState.collapsed, true) => (SidebarDock.rail, SidebarFloat.none),
    (SidebarState.open || SidebarState.collapsed, false) => (
        SidebarDock.rail,
        q.drawerShown ? SidebarFloat.drawer : SidebarFloat.none,
      ),
    (SidebarState.hidden, _) => (SidebarDock.none, SidebarFloat.none),
  };
  final hidden = q.sidebar == SidebarState.hidden;
  return (
    strip: false,
    dock: dock,
    float: float,
    arrowTab: hidden,
    tabCountButton: true,
    stripButton: false,
  );
}

/// Where a drag of the sidebar's edge lets go: the nearest of hidden (0),
/// the rail ([rail]) and open ([width]).
SidebarState settleSidebar({
  required double visible,
  required double width,
  required double rail,
}) {
  final stops = [
    (0.0, SidebarState.hidden),
    (rail, SidebarState.collapsed),
    (width, SidebarState.open),
  ];
  var best = stops.first;
  for (final stop in stops) {
    if ((stop.$1 - visible).abs() < (best.$1 - visible).abs()) best = stop;
  }
  return best.$2;
}

/// Whether the back gesture's navigation (NAV-009) opens a drawer over the
/// page, which the next gesture may escalate from: the legacy design's
/// drawer, or its sidebar's drawer on a phone. The library's goes to the
/// webspaces, and a docked sidebar is no drawer.
bool backOpensDrawer({
  required bool libraryDesign,
  required SiteNavigation navigation,
  required bool wide,
}) =>
    !libraryDesign && (navigation != SiteNavigation.sidebar || !wide);

/// Whether the menu the back gesture would open (NAV-009) is already on
/// screen beside the page: the legacy design's sidebar docked open, which
/// Back then leaves the app from as from a drawer it opened (TAB-036).
bool backMenuShown({required bool libraryDesign, required SidebarDock dock}) =>
    !libraryDesign && dock == SidebarDock.full;

/// Whether a right swipe from the screen's edge over the docked sidebar is
/// the page's back swipe: where the webview's own back swipe answers only at
/// the screen's edge ([screenEdgeBack], Apple's), a docked sidebar takes that
/// edge from it (NAV-001).
bool edgeSwipeGoesBack({
  required bool screenEdgeBack,
  required SidebarDock dock,
}) =>
    screenEdgeBack && dock != SidebarDock.none;

/// Whether Expand rail on hover is offered: only where a pointer can rest on
/// the rail, a desktop or a device with a mouse or trackpad connected
/// (APPSET-005).
bool railHoverOffered({required bool desktop, required bool pointer}) =>
    desktop || pointer;
