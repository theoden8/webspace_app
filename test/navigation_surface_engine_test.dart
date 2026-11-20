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
  bool wide = true,
  bool kioskLocked = false,
  bool siteOnScreen = true,
  bool revealed = false,
}) =>
    navigationSurfaces((
      navigation: navigation,
      inFullscreen: inFullscreen,
      fullscreen: fullscreen,
      sidebar: sidebar,
      wide: wide,
      kioskLocked: kioskLocked,
      siteOnScreen: siteOnScreen,
      revealed: revealed,
    ));

const NavigationSurfaces nothing = (
  strip: false,
  dock: SidebarDock.none,
  float: SidebarFloat.none,
  arrowTab: false,
  appBarSidebarIcon: false,
  tabCountButton: false,
  stripButton: false,
);

void main() {
  group('tab button', () {
    test('shows only the tab count', () {
      expect(surfaces(navigation: SiteNavigation.tabButton),
          (
            strip: false,
            dock: SidebarDock.none,
            float: SidebarFloat.none,
            arrowTab: false,
            appBarSidebarIcon: false,
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
      expect((s.arrowTab, s.appBarSidebarIcon, s.tabCountButton, s.strip),
          (false, false, false, false));
    });

    test('collapsed docks the rail, with no arrow tab', () {
      final s = surfaces(sidebar: SidebarState.collapsed);
      expect(s.dock, SidebarDock.rail);
      expect((s.arrowTab, s.appBarSidebarIcon), (false, false));
    });

    test('hidden shows the arrow tab and the app-bar icon', () {
      final s = surfaces(sidebar: SidebarState.hidden);
      expect(s.dock, SidebarDock.none);
      expect((s.arrowTab, s.appBarSidebarIcon, s.strip), (true, true, false));
    });
  });

  group('sidebar, phone', () {
    test('open is the rail with the drawer over the page', () {
      final s = surfaces(wide: false);
      expect((s.dock, s.float), (SidebarDock.rail, SidebarFloat.drawer));
      expect(s.arrowTab, isFalse);
    });

    test('collapsed is the rail alone', () {
      final s = surfaces(wide: false, sidebar: SidebarState.collapsed);
      expect((s.dock, s.float, s.arrowTab),
          (SidebarDock.rail, SidebarFloat.none, false));
    });

    test('hidden shows the arrow tab and the app-bar icon', () {
      final s = surfaces(wide: false, sidebar: SidebarState.hidden);
      expect((s.dock, s.arrowTab, s.appBarSidebarIcon),
          (SidebarDock.none, true, true));
    });
  });

  group('sidebar, full screen', () {
    test('Button puts it away behind the arrow tab', () {
      final s = surfaces(
          fullscreen: true, inFullscreen: FullscreenNavigation.button);
      expect((s.dock, s.float, s.arrowTab, s.appBarSidebarIcon),
          (SidebarDock.none, SidebarFloat.none, true, false));
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

    test('Kept docks it as out of full screen, with no app-bar icon', () {
      final s = surfaces(
          fullscreen: true,
          inFullscreen: FullscreenNavigation.kept,
          sidebar: SidebarState.collapsed);
      expect(s.dock, SidebarDock.rail);
      final hidden = surfaces(
          fullscreen: true,
          inFullscreen: FullscreenNavigation.kept,
          sidebar: SidebarState.hidden);
      expect((hidden.arrowTab, hidden.appBarSidebarIcon), (true, false));
    });

    test('Hidden shows nothing', () {
      expect(
          surfaces(fullscreen: true, inFullscreen: FullscreenNavigation.hidden),
          nothing);
    });
  });

  test('no site on screen or a locked kiosk shows nothing', () {
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

  test('a narrowing window keeps the sidebar at the rail, not over the page',
      () {
    expect(sidebarOnNarrowing(SidebarState.open), SidebarState.collapsed);
    expect(sidebarOnNarrowing(SidebarState.collapsed), SidebarState.collapsed);
    expect(sidebarOnNarrowing(SidebarState.hidden), SidebarState.hidden);
  });
}
