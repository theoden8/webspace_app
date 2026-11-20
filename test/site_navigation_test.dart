// Site navigation: one choice of how sites and tabs are reached, and the
// one-time read of today's site strip prefs into it, so no layout changes on
// upgrade.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/settings/site_navigation.dart';

void main() {
  setUp(() async {
    isDemoMode = false;
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
  });

  group('siteNavigationFrom', () {
    test('the strip button maps to the strip with the button in full screen',
        () {
      expect(
        siteNavigationFrom(
            showTabStrip: false, tabBarButton: true, tabStripInFullscreen: false),
        (navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.button),
      );
    });

    test('a pinned strip kept in full screen maps to kept', () {
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: false, tabStripInFullscreen: true),
        (navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.kept),
      );
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: false, tabStripInFullscreen: false),
        (navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.hidden),
      );
    });

    test('no strip maps to the tab button', () {
      expect(
        siteNavigationFrom(
            showTabStrip: false, tabBarButton: false, tabStripInFullscreen: false),
        (navigation: SiteNavigation.tabButton, inFullscreen: FullscreenNavigation.hidden),
      );
    });

    test('the button wins over a pinned strip, as the strip choice read today',
        () {
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: true, tabStripInFullscreen: true),
        (navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.button),
      );
    });
  });

  group('loadSiteNavigation', () {
    Future<SharedPreferences> launch(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      final prefs = await SharedPreferences.getInstance();
      AppPref.loadAll(prefs);
      await loadSiteNavigation(prefs);
      return prefs;
    }

    test('reads the strip prefs once into the new choice', () async {
      final prefs = await launch({'tabBarButton': true});
      expect(currentSiteNavigation, SiteNavigation.strip);
      expect(currentFullscreenNavigation, FullscreenNavigation.button);
      expect(prefs.get(AppPref.siteNavigation.key), 'strip');
      expect(prefs.get(AppPref.fullscreenNavigation.key), 'button');
    });

    test('reads the strip button under its name before v0.2.7', () async {
      await launch({'tabBarButtonInFullscreen': true});
      expect(currentSiteNavigation, SiteNavigation.strip);
      expect(currentFullscreenNavigation, FullscreenNavigation.button);
    });

    test('leaves a choice already made', () async {
      await launch({'siteNavigation': 'sidebar', 'tabBarButton': true});
      expect(currentSiteNavigation, SiteNavigation.sidebar);
    });

    test('a new install starts on the tab button', () async {
      final prefs = await launch({});
      expect(currentSiteNavigation, SiteNavigation.tabButton);
      expect(currentFullscreenNavigation, FullscreenNavigation.hidden);
      expect(prefs.get(AppPref.siteNavigation.key), 'tabButton');
    });
  });

  test('an old backup imports its strip choice', () {
    final prefs = resolveExportedAppPrefs(
        {'showTabStrip': true, 'tabStripInFullscreen': true});
    expect(prefs[AppPref.siteNavigation.key], 'strip');
    expect(prefs[AppPref.fullscreenNavigation.key], 'kept');
  });

  test('a backup that names the choice keeps it over the old keys', () {
    final prefs = resolveExportedAppPrefs(
        {'siteNavigation': 'sidebar', 'tabBarButton': true});
    expect(prefs[AppPref.siteNavigation.key], 'sidebar');
  });

  test('the open sidebar shows squares by default, in an open state', () {
    expect(currentSidebarStyle, SidebarStyle.squares);
    expect(currentSidebarState, SidebarState.open);
  });

  test('a stored value no build wrote reads as the default', () async {
    SharedPreferences.setMockInitialValues(
        {'siteNavigation': 'carousel', 'sidebarState': 'folded'});
    AppPref.loadAll(await SharedPreferences.getInstance());
    expect(currentSiteNavigation, SiteNavigation.tabButton);
    expect(currentSidebarState, SidebarState.open);
  });
}
