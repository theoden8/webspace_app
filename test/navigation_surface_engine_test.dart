// Which navigation surfaces show, decided once from the settings and the
// page's state: the tables of the site navigation design, row by row.

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/settings/navigation_choices.dart';

NavigationSurfaces surfaces({
  SiteNavigation navigation = SiteNavigation.sidebar,
  FullscreenNavigation inFullscreen = FullscreenNavigation.hidden,
  bool fullscreen = false,
  SidebarState sidebar = SidebarState.open,
  bool drawerShown = false,
  bool wide = true,
  bool kioskLocked = false,
  bool siteOnScreen = true,
  bool legacyWebspace = false,
  bool revealed = false,
}) =>
    navigationSurfaces((
      navigation: navigation,
      inFullscreen: inFullscreen,
      fullscreen: fullscreen,
      sidebar: sidebar,
      drawerShown: drawerShown,
      wide: wide,
      kioskLocked: kioskLocked,
      siteOnScreen: siteOnScreen,
      legacyWebspace: legacyWebspace,
      revealed: revealed,
    ));

const NavigationSurfaces nothing = (
  strip: false,
  dock: SidebarDock.none,
  float: SidebarFloat.none,
  arrowTab: false,
  tabCountButton: false,
  stripButton: false,
);

void main() {
  group('tab button', () {
    test('shows only the tab count (TAB-030)', () {
      expect(surfaces(navigation: SiteNavigation.tabButton),
          (
            strip: false,
            dock: SidebarDock.none,
            float: SidebarFloat.none,
            arrowTab: false,
            tabCountButton: true,
            stripButton: false,
          ));
    });

    test('full screen shows nothing, whatever the full-screen choice', () {
      for (final choice in FullscreenNavigation.values) {
        expect(
            surfaces(
                navigation: SiteNavigation.tabButton,
                fullscreen: true,
                inFullscreen: choice),
            nothing,
            reason: choice.name);
      }
    });
  });

  group('site strip', () {
    test('out of full screen the strip shows, with no tab count', () {
      final s = surfaces(navigation: SiteNavigation.strip);
      expect(s.strip, isTrue);
      expect(s.tabCountButton, isFalse);
      expect(s.stripButton, isFalse);
      expect(s.dock, SidebarDock.none);
    });

    test('full screen set to Button leaves its button until it reveals it',
        () {
      final hidden = surfaces(
          navigation: SiteNavigation.strip,
          fullscreen: true,
          inFullscreen: FullscreenNavigation.button);
      expect((hidden.strip, hidden.stripButton), (false, true));
      final shown = surfaces(
          navigation: SiteNavigation.strip,
          fullscreen: true,
          inFullscreen: FullscreenNavigation.button,
          revealed: true);
      expect((shown.strip, shown.stripButton), (true, false));
    });

    test('full screen keeps it, or hides it', () {
      expect(
          surfaces(
                  navigation: SiteNavigation.strip,
                  fullscreen: true,
                  inFullscreen: FullscreenNavigation.kept)
              .strip,
          isTrue);
      expect(
          surfaces(
              navigation: SiteNavigation.strip,
              fullscreen: true,
              inFullscreen: FullscreenNavigation.hidden),
          nothing);
    });
  });

  group('sidebar, wide window', () {
    test('open docks the full sidebar and needs no other control', () {
      final s = surfaces();
      expect(s.dock, SidebarDock.full);
      expect(s.float, SidebarFloat.none);
      expect((s.arrowTab, s.tabCountButton, s.strip), (false, false, false));
    });

    test('collapsed docks the rail, with no arrow tab', () {
      final s = surfaces(sidebar: SidebarState.collapsed);
      expect(s.dock, SidebarDock.rail);
      expect(s.arrowTab, isFalse);
    });

    test('hidden shows the arrow tab, its one way back', () {
      final s = surfaces(sidebar: SidebarState.hidden);
      expect(s.dock, SidebarDock.none);
      expect((s.arrowTab, s.strip), (true, false));
    });
  });

  group('sidebar, phone', () {
    test('open is the rail; the drawer shows over the page only when '
        'opened (TAB-033)', () {
      expect(surfaces(wide: false).float, SidebarFloat.none);
      final s = surfaces(wide: false, drawerShown: true);
      expect((s.dock, s.float), (SidebarDock.rail, SidebarFloat.drawer));
      expect(s.arrowTab, isFalse);
    });

    test('collapsed is the rail alone', () {
      final s = surfaces(wide: false, sidebar: SidebarState.collapsed);
      expect((s.dock, s.float, s.arrowTab),
          (SidebarDock.rail, SidebarFloat.none, false));
    });

    test('hidden shows the arrow tab, its one way back', () {
      final s = surfaces(wide: false, sidebar: SidebarState.hidden);
      expect((s.dock, s.arrowTab), (SidebarDock.none, true));
    });
  });

  group('sidebar, full screen', () {
    test('Button puts it away behind the arrow tab', () {
      final s = surfaces(
          fullscreen: true, inFullscreen: FullscreenNavigation.button);
      expect((s.dock, s.float, s.arrowTab),
          (SidebarDock.none, SidebarFloat.none, true));
    });

    test('revealed, it shows over the page: an overlay wide, a drawer on a '
        'phone', () {
      final wide = surfaces(
          fullscreen: true,
          inFullscreen: FullscreenNavigation.button,
          revealed: true);
      expect((wide.float, wide.arrowTab), (SidebarFloat.overlay, false));
      final phone = surfaces(
          wide: false,
          fullscreen: true,
          inFullscreen: FullscreenNavigation.button,
          revealed: true);
      expect((phone.float, phone.arrowTab), (SidebarFloat.drawer, false));
    });

    test('Kept docks it as out of full screen', () {
      final s = surfaces(
          fullscreen: true,
          inFullscreen: FullscreenNavigation.kept,
          sidebar: SidebarState.collapsed);
      expect(s.dock, SidebarDock.rail);
      final hidden = surfaces(
          fullscreen: true,
          inFullscreen: FullscreenNavigation.kept,
          sidebar: SidebarState.hidden);
      expect(hidden.arrowTab, isTrue);
    });

    test('Hidden shows nothing', () {
      expect(
          surfaces(fullscreen: true, inFullscreen: FullscreenNavigation.hidden),
          nothing);
    });
  });

  test('no site on screen or a locked kiosk shows nothing (TAB-030)', () {
    for (final navigation in SiteNavigation.values) {
      expect(surfaces(navigation: navigation, siteOnScreen: false), nothing,
          reason: '${navigation.name}, no site');
      expect(surfaces(navigation: navigation, kioskLocked: true), nothing,
          reason: '${navigation.name}, kiosk');
    }
  });

  group('settleSidebar', () {
    test('lets go at the nearest of hidden, the rail and open', () {
      expect(settleSidebar(visible: 10, width: 260, rail: 60), SidebarState.hidden);
      expect(settleSidebar(visible: 50, width: 260, rail: 60), SidebarState.collapsed);
      expect(settleSidebar(visible: 200, width: 260, rail: 60), SidebarState.open);
    });
  });

  test('full screen set to Button gives a floating control with the strip or '
      'the sidebar, and the bars stay revealable for it', () {
    for (final navigation in SiteNavigation.values) {
      for (final inFullscreen in FullscreenNavigation.values) {
        expect(
            floatsInFullscreen(
                navigation: navigation, inFullscreen: inFullscreen),
            navigation != SiteNavigation.tabButton &&
                inFullscreen == FullscreenNavigation.button,
            reason: '${navigation.name}, ${inFullscreen.name}');
      }
    }
  });

  test('the legacy design lists a picked webspace in its sidebar with no '
      'site on screen, as its drawer did; nothing else shows there', () {
    final listed = surfaces(siteOnScreen: false, legacyWebspace: true);
    expect(listed.dock, SidebarDock.full);
    for (final navigation in [SiteNavigation.tabButton, SiteNavigation.strip]) {
      expect(
          surfaces(
              navigation: navigation,
              siteOnScreen: false,
              legacyWebspace: true),
          nothing,
          reason: navigation.name);
    }
    expect(
        surfaces(
            siteOnScreen: false, legacyWebspace: true, kioskLocked: true),
        nothing);
  });

  test('NAV-009: the back gesture opens a drawer it may escalate from only in '
      'the legacy design, and with the sidebar only on a phone', () {
    for (final navigation in SiteNavigation.values) {
      for (final wide in [true, false]) {
        expect(
            backOpensDrawer(
                libraryDesign: true, navigation: navigation, wide: wide),
            isFalse,
            reason: 'the library: Back goes to the webspaces');
        expect(
            backOpensDrawer(
                libraryDesign: false, navigation: navigation, wide: wide),
            navigation != SiteNavigation.sidebar || !wide,
            reason: '${navigation.name}, wide: $wide');
      }
    }
  });

  test('TAB-036: the legacy design\'s docked open sidebar is the menu Back '
      'would open; the library\'s, the rail and a drawer are not', () {
    expect(backMenuShown(libraryDesign: false, dock: SidebarDock.full), isTrue);
    expect(backMenuShown(libraryDesign: true, dock: SidebarDock.full), isFalse);
    expect(backMenuShown(libraryDesign: false, dock: SidebarDock.rail), isFalse);
    expect(backMenuShown(libraryDesign: false, dock: SidebarDock.none), isFalse);
  });

  test('NAV-001, TAB-033: on iOS a docked sidebar takes the screen edge from '
      'the webview, so its edge swipe is the page\'s back swipe', () {
    for (final dock in SidebarDock.values) {
      expect(edgeSwipeGoesBack(screenEdgeBack: true, dock: dock),
          dock != SidebarDock.none,
          reason: dock.name);
      expect(edgeSwipeGoesBack(screenEdgeBack: false, dock: dock), isFalse,
          reason: 'where the system takes the edge itself, ${dock.name}');
    }
  });
}
