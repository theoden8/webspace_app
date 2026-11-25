import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/navigation_choices.dart';
import 'package:webspace/settings/pref_read.dart';

export 'package:webspace/settings/navigation_choices.dart';

/// The chosen navigation, as the app runs with it.
SiteNavigation get currentSiteNavigation =>
    SiteNavigation.parse(AppPref.siteNavigation.value);

/// What full screen does with it.
FullscreenNavigation get currentFullscreenNavigation =>
    FullscreenNavigation.parse(AppPref.fullscreenNavigation.value);

/// Switches to [to], shown or [hidden] behind its control: the strip's
/// button, the sidebar's arrow tab (TAB-038). The one way the navigation in
/// use changes, as its control is dragged.
Future<void> useSiteNavigation(
  SiteNavigation to, {
  required bool hidden,
}) async {
  await AppPref.siteNavigation.set(to.name);
  switch (to) {
    case SiteNavigation.strip:
      await AppPref.siteStripHidden.set(hidden);
    case SiteNavigation.sidebar:
      await AppPref.sidebarState.set(
          (hidden ? SidebarState.hidden : SidebarState.open).name);
  }
}

/// The sidebar's state, one for the app.
SidebarState get currentSidebarState =>
    SidebarState.parse(AppPref.sidebarState.value);

/// What the open sidebar shows.
SidebarStyle get currentSidebarStyle =>
    SidebarStyle.parse(AppPref.sidebarStyle.value);

typedef SiteNavigationChoice = ({
  SiteNavigation navigation,
  FullscreenNavigation inFullscreen,
  // The sidebar starts hidden behind its arrow tab: the choice showed neither
  // the strip nor the sidebar.
  bool sidebarHidden,
});

/// What the site strip prefs of a build before [AppPref.siteNavigation]
/// chose, as the choice now: a strip, pinned or behind its button, is the
/// strip, its button or a strip kept in full screen the full-screen button;
/// nothing set was the tab button alone, which is the sidebar hidden behind
/// its arrow tab, kept in full screen (TAB-030, FS-007). The button wins
/// over a pinned strip, as the strip's presentation read it.
SiteNavigationChoice siteNavigationFrom({
  required bool showTabStrip,
  required bool tabBarButton,
  required bool tabStripInFullscreen,
}) {
  if (tabBarButton) {
    return (
      navigation: SiteNavigation.strip,
      inFullscreen: FullscreenNavigation.button,
      sidebarHidden: false,
    );
  }
  if (showTabStrip) {
    return (
      navigation: SiteNavigation.strip,
      inFullscreen: tabStripInFullscreen
          ? FullscreenNavigation.button
          : FullscreenNavigation.hidden,
      sidebarHidden: false,
    );
  }
  return (
    navigation: SiteNavigation.sidebar,
    inFullscreen: FullscreenNavigation.button,
    sidebarHidden: true,
  );
}

/// What a build that offered it saved for the tab button alone.
const String _tabButton = 'tabButton';

/// The strip prefs an earlier build saved, read only into the new choice.
const String _showTabStripKey = 'showTabStrip';
const String _tabBarButtonKey = 'tabBarButton';
const String _tabBarButtonBeforeV027Key = 'tabBarButtonInFullscreen';
const String _tabStripInFullscreenKey = 'tabStripInFullscreen';

/// Every key [siteNavigationFrom] is read from, in a backup or on a device.
const Set<String> siteNavigationLegacyKeys = {
  _showTabStripKey,
  _tabBarButtonKey,
  _tabBarButtonBeforeV027Key,
  _tabStripInFullscreenKey,
};

/// [values] with the choice as it is now: a backup that names the tab
/// button has the sidebar hidden instead, and one from a build before
/// [AppPref.siteNavigation] the choice its old strip keys made.
Map<String, Object?> withSiteNavigation(Map<String, Object?> values) {
  final named = values[AppPref.siteNavigation.key];
  if (named == _tabButton) {
    return {
      ...values,
      AppPref.siteNavigation.key: SiteNavigation.sidebar.name,
      AppPref.sidebarState.key: SidebarState.hidden.name,
    };
  }
  if (named != null) return values;
  bool flag(String key) => values[key] == true;
  final choice = siteNavigationFrom(
    showTabStrip: flag(_showTabStripKey),
    tabBarButton: flag(_tabBarButtonKey) || flag(_tabBarButtonBeforeV027Key),
    tabStripInFullscreen: flag(_tabStripInFullscreenKey),
  );
  return {
    ...values,
    AppPref.siteNavigation.key: choice.navigation.name,
    if (!values.containsKey(AppPref.fullscreenNavigation.key))
      AppPref.fullscreenNavigation.key: choice.inFullscreen.name,
    if (choice.sidebarHidden) AppPref.sidebarState.key: SidebarState.hidden.name,
  };
}

/// Loads [AppPref.siteNavigation] and [AppPref.fullscreenNavigation],
/// deciding them once on the first launch that knows them from what an
/// earlier build's strip prefs chose, so no layout changes on upgrade; a
/// tab button an earlier build saved becomes the sidebar hidden behind its
/// arrow tab, which shows no more of the page than it did.
Future<void> loadSiteNavigation(SharedPreferences prefs) async {
  final stored = readPrefAs<String>(prefs, key: AppPref.siteNavigation.key);
  if (stored == _tabButton) {
    await AppPref.siteNavigation.set(SiteNavigation.sidebar.name);
    await AppPref.sidebarState.set(SidebarState.hidden.name);
    AppPref.fullscreenNavigation.load(prefs);
    return;
  }
  if (stored != null) {
    AppPref.siteNavigation.load(prefs);
    AppPref.fullscreenNavigation.load(prefs);
    return;
  }
  // Each key read by name, so the backup compat scan sees it is still read.
  final choice = siteNavigationFrom(
    showTabStrip: readPrefAs<bool>(prefs, key: _showTabStripKey) ?? false,
    tabBarButton: (readPrefAs<bool>(prefs, key: _tabBarButtonKey) ?? false) ||
        (readPrefAs<bool>(prefs, key: _tabBarButtonBeforeV027Key) ?? false),
    tabStripInFullscreen:
        readPrefAs<bool>(prefs, key: _tabStripInFullscreenKey) ?? false,
  );
  await AppPref.siteNavigation.set(choice.navigation.name);
  await AppPref.fullscreenNavigation.set(choice.inFullscreen.name);
  if (choice.sidebarHidden) {
    await AppPref.sidebarState.set(SidebarState.hidden.name);
  }
}
