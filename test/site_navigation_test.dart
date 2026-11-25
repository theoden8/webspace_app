// Site navigation: the strip or the sidebar, set where its control rests,
// and the one-time read of an earlier build's choice into it, so no layout
// shows more of the page than it did on upgrade.

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
        (
          navigation: SiteNavigation.strip,
          inFullscreen: FullscreenNavigation.button,
          sidebarHidden: false,
        ),
      );
    });

    test('FS-007 a pinned strip kept in full screen maps to the button there',
        () {
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: false, tabStripInFullscreen: true),
        (
          navigation: SiteNavigation.strip,
          inFullscreen: FullscreenNavigation.button,
          sidebarHidden: false,
        ),
      );
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: false, tabStripInFullscreen: false),
        (
          navigation: SiteNavigation.strip,
          inFullscreen: FullscreenNavigation.hidden,
          sidebarHidden: false,
        ),
      );
    });

    test('TAB-030, FS-007 no strip maps to the sidebar hidden behind its arrow '
        'tab, which full screen keeps', () {
      expect(
        siteNavigationFrom(
            showTabStrip: false, tabBarButton: false, tabStripInFullscreen: false),
        (
          navigation: SiteNavigation.sidebar,
          inFullscreen: FullscreenNavigation.button,
          sidebarHidden: true,
        ),
      );
    });

    test('the button wins over a pinned strip, as the strip choice read today',
        () {
      expect(
        siteNavigationFrom(
            showTabStrip: true, tabBarButton: true, tabStripInFullscreen: true),
        (
          navigation: SiteNavigation.strip,
          inFullscreen: FullscreenNavigation.button,
          sidebarHidden: false,
        ),
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

    test('reads the strip prefs once into the new choice (TAB-030)', () async {
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

    test('TAB-030 a new install starts with the sidebar hidden', () async {
      final prefs = await launch({});
      expect(currentSiteNavigation, SiteNavigation.sidebar);
      expect(currentSidebarState, SidebarState.hidden);
      expect(currentFullscreenNavigation, FullscreenNavigation.button,
          reason: 'FS-007: the arrow tab stays in full screen by default');
      expect(prefs.get(AppPref.siteNavigation.key), 'sidebar');
    });

    test('TAB-030 the tab button an earlier build saved becomes the sidebar '
        'hidden behind its arrow tab', () async {
      final prefs = await launch(
          {'siteNavigation': 'tabButton', 'sidebarState': 'open'});
      expect(currentSiteNavigation, SiteNavigation.sidebar);
      expect(currentSidebarState, SidebarState.hidden);
      expect(currentFullscreenNavigation, FullscreenNavigation.button);
      expect(prefs.get(AppPref.siteNavigation.key), 'sidebar');
    });

    test('FS-007 kept in full screen an earlier build saved is the button',
        () async {
      await launch({'siteNavigation': 'strip', 'fullscreenNavigation': 'kept'});
      expect(currentFullscreenNavigation, FullscreenNavigation.button);
    });
  });

  test('an old backup imports its strip choice (TAB-030)', () {
    final prefs = resolveExportedAppPrefs(
        {'showTabStrip': true, 'tabStripInFullscreen': true});
    expect(prefs[AppPref.siteNavigation.key], 'strip');
    expect(prefs[AppPref.fullscreenNavigation.key], 'button');
  });

  test('TAB-030 a backup that names the tab button imports the sidebar hidden',
      () {
    final prefs = resolveExportedAppPrefs(
        {'siteNavigation': 'tabButton', 'sidebarState': 'open'});
    expect(prefs[AppPref.siteNavigation.key], 'sidebar');
    expect(prefs[AppPref.sidebarState.key], 'hidden');
    expect(prefs[AppPref.fullscreenNavigation.key], 'button');
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
    expect(currentSiteNavigation, SiteNavigation.sidebar);
    expect(currentSidebarState, SidebarState.open);
  });

  test('TAB-038 switching to the strip or the sidebar sets where it rests',
      () async {
    await useSiteNavigation(SiteNavigation.strip, hidden: true);
    expect(currentSiteNavigation, SiteNavigation.strip);
    expect(AppPref.siteStripHidden.value, isTrue);

    await useSiteNavigation(SiteNavigation.sidebar, hidden: true);
    expect(currentSiteNavigation, SiteNavigation.sidebar);
    expect(currentSidebarState, SidebarState.hidden);

    await useSiteNavigation(SiteNavigation.strip, hidden: false);
    expect(AppPref.siteStripHidden.value, isFalse);
    await useSiteNavigation(SiteNavigation.sidebar, hidden: false);
    expect(currentSidebarState, SidebarState.open);
  });
}
