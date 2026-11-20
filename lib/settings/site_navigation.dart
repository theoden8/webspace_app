import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';

/// How the sites and their tabs are reached: the app bar's tab-count button
/// alone, the site strip, or the sidebar. One choice, so the strip and the
/// sidebar never show together.
enum SiteNavigation {
  tabButton,
  strip,
  sidebar;

  static SiteNavigation get current =>
      values.asNameMap()[AppPref.siteNavigation.value] ?? tabButton;
}

/// What full screen does with the chosen navigation: hides it, keeps it, or
/// leaves a small control that brings it back.
enum FullscreenNavigation {
  hidden,
  kept,
  button;

  static FullscreenNavigation get current =>
      values.asNameMap()[AppPref.fullscreenNavigation.value] ?? hidden;
}

/// The sidebar's state, one for the app: open, collapsed to a rail, hidden.
enum SidebarState {
  open,
  collapsed,
  hidden;

  static SidebarState get current =>
      values.asNameMap()[AppPref.sidebarState.value] ?? open;
}

/// What the open sidebar shows: the sites as squares, their tabs opening
/// out under them, or the tab tree.
enum SidebarStyle {
  squares,
  tree;

  static SidebarStyle get current =>
      values.asNameMap()[AppPref.sidebarStyle.value] ?? squares;
}

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
