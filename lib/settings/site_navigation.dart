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

/// The sidebar's state, one for the app.
SidebarState get currentSidebarState =>
    SidebarState.parse(AppPref.sidebarState.value);

/// What the open sidebar shows.
SidebarStyle get currentSidebarStyle =>
    SidebarStyle.parse(AppPref.sidebarStyle.value);

typedef SiteNavigationChoice = ({
  SiteNavigation navigation,
  FullscreenNavigation inFullscreen,
});

/// What the site strip prefs of a build before [AppPref.siteNavigation]
/// chose, as the new choice: a strip, pinned or behind its button, is the
/// strip; its button is the full-screen control; nothing set is the tab
/// button. The button wins over a pinned strip, as the strip's presentation
/// read it.
SiteNavigationChoice siteNavigationFrom({
  required bool showTabStrip,
  required bool tabBarButton,
  required bool tabStripInFullscreen,
}) {
  if (tabBarButton) {
    return (navigation: SiteNavigation.strip, inFullscreen: FullscreenNavigation.button);
  }
  if (showTabStrip) {
    return (
      navigation: SiteNavigation.strip,
      inFullscreen: tabStripInFullscreen ? FullscreenNavigation.kept : FullscreenNavigation.hidden,
    );
  }
  return (navigation: SiteNavigation.tabButton, inFullscreen: FullscreenNavigation.hidden);
}

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

/// [values] with the choice its old strip keys made, where it names no
/// choice of its own: a backup from a build before [AppPref.siteNavigation].
Map<String, Object?> withSiteNavigation(Map<String, Object?> values) {
  if (values.containsKey(AppPref.siteNavigation.key) ||
      !siteNavigationLegacyKeys.any(values.containsKey)) {
    return values;
  }
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
  };
}

/// Loads [AppPref.siteNavigation] and [AppPref.fullscreenNavigation],
/// deciding them once on the first launch that knows them from what an
/// earlier build's strip prefs chose, so no layout changes on upgrade.
Future<void> loadSiteNavigation(SharedPreferences prefs) async {
  if (prefs.containsKey(AppPref.siteNavigation.key)) {
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
}
