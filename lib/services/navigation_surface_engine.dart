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
});

/// Whether full screen shows a floating control (the strip's button or the
/// sidebar's arrow tab), so the system bars stay revealable rather than
/// sticky, as they are with nothing of the app's on screen.
bool floatsInFullscreen({
  required SiteNavigation navigation,
  required FullscreenNavigation inFullscreen,
}) =>
    navigation != SiteNavigation.tabButton &&
    inFullscreen == FullscreenNavigation.button;

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
    SiteNavigation.tabButton => q.fullscreen ? _none : _tabButton,
    SiteNavigation.strip => _strip(q),
    SiteNavigation.sidebar => _sidebar(q),
  };
}

const NavigationSurfaces _tabButton = (
  strip: false,
  dock: SidebarDock.none,
  float: SidebarFloat.none,
  arrowTab: false,
  tabCountButton: true,
  stripButton: false,
);

NavigationSurfaces _strip(NavigationQuery q) {
  final (strip, button) = !q.fullscreen
      ? (true, false)
      : switch (q.inFullscreen) {
          FullscreenNavigation.kept => (true, false),
          FullscreenNavigation.button => (q.revealed, !q.revealed),
          FullscreenNavigation.hidden => (false, false),
        };
  return (
    strip: strip,
    dock: SidebarDock.none,
    float: SidebarFloat.none,
    arrowTab: false,
    tabCountButton: false,
    stripButton: button,
  );
}

NavigationSurfaces _sidebar(NavigationQuery q) {
  if (q.fullscreen) {
    switch (q.inFullscreen) {
      case FullscreenNavigation.hidden:
        return _none;
      case FullscreenNavigation.button:
        return (
          strip: false,
          dock: SidebarDock.none,
          float: !q.revealed
              ? SidebarFloat.none
              : (q.wide ? SidebarFloat.overlay : SidebarFloat.drawer),
          arrowTab: !q.revealed,
          tabCountButton: false,
          stripButton: false,
        );
      case FullscreenNavigation.kept:
        break;
    }
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
    tabCountButton: false,
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
