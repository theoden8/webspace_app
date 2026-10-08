import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/settings/app_prefs.dart';

/// What a site's overflow menu offers, in menu order.
enum SiteMenuAction {
  newTab,
  backToWebspaces,
  search,
  webSearch,
  toggleUrlBar,
  fullscreen,
  repaint,
  settings,
  devTools,
  addToHome,
}

/// Where a site's overflow menu sits: the app bar, or the bottom bar while
/// the tab strip is on.
enum SiteMenuPlacement { appBar, bottomBar }

/// What the menu shows for the site on screen, read when it opens.
typedef SiteMenuState = ({
  bool loading,
  bool tabsOn,
  bool tabsFeature,
  bool fullscreen,
  bool offersShortcut,
});

/// The buttons of the menu's top row. Each closes the menu, then acts.
typedef SiteMenuNav = ({
  VoidCallback back,
  VoidCallback home,
  VoidCallback share,
  VoidCallback reload,
  VoidCallback stop,

  /// A long press on reload, where the site has tabs (TAB-010).
  VoidCallback? duplicateTab,
});

/// A site's overflow menu: back, home, share and reload in a row, then the
/// actions offered at [placement].
class SiteMenuButton extends StatelessWidget {
  const SiteMenuButton({
    super.key,
    required this.placement,
    required this.state,
    required this.nav,
    required this.onSelected,
  });

  final SiteMenuPlacement placement;
  final SiteMenuState Function() state;
  final SiteMenuNav nav;
  final ValueChanged<SiteMenuAction> onSelected;

  @override
  Widget build(BuildContext context) => switch (placement) {
        SiteMenuPlacement.appBar => PopupMenuButton<SiteMenuAction>(
            itemBuilder: _items,
            onSelected: onSelected,
          ),
        SiteMenuPlacement.bottomBar => PopupMenuButton<SiteMenuAction>(
            icon: Icon(Icons.more_vert, size: 20),
            padding: EdgeInsets.zero,
            tooltip: AppLocalizations.of(context).homeMenuTooltip,
            itemBuilder: _items,
            onSelected: onSelected,
          ),
      };

  List<PopupMenuEntry<SiteMenuAction>> _items(BuildContext menuContext) {
    final loc = AppLocalizations.of(menuContext);
    final s = state();
    return [
      _navRow(menuContext, loc: loc, loading: s.loading),
      PopupMenuDivider(),
      for (final action in SiteMenuAction.values)
        if (_entry(action, state: s, loc: loc) case (final icon, final label))
          PopupMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(icon),
                SizedBox(width: 8),
                Flexible(child: Text(label)),
              ],
            ),
          ),
    ];
  }

  /// Icon and label of [action] in this menu, or null where it does not
  /// offer it.
  (IconData, String)? _entry(
    SiteMenuAction action, {
    required SiteMenuState state,
    required AppLocalizations loc,
  }) =>
      switch (action) {
        SiteMenuAction.newTab =>
          state.tabsOn ? (Icons.add, loc.tabsNewTab) : null,
        SiteMenuAction.backToWebspaces =>
          placement == SiteMenuPlacement.bottomBar
              ? (Icons.arrow_back, loc.homeBackToWebspaces)
              : null,
        SiteMenuAction.search => (Icons.search, loc.homeFindMenu),
        // Where the site has tabs, web search lives in the Tabs sheet.
        SiteMenuAction.webSearch => state.tabsFeature && !state.tabsOn
            ? (Icons.travel_explore, loc.webSearchMenu)
            : null,
        SiteMenuAction.toggleUrlBar => AppPref.showUrlBar.value
            ? (Icons.visibility_off, loc.homeHideUrlBarMenu)
            : (Icons.visibility, loc.homeShowUrlBarMenu),
        SiteMenuAction.fullscreen => state.fullscreen
            ? (Icons.fullscreen_exit, loc.homeExitFullScreenMenu)
            : (Icons.fullscreen, loc.homeFullScreenMenu),
        // Manual escape hatch for the recurring Android blank surface
        // (BUG-001 / PAUSE-028): every automatic trigger is an enumerated
        // code path, and the user is the only one who can see a path nobody
        // enumerated. Android-only, where the nudge is not a no-op, and
        // behind developer mode: it is a diagnostic, not something to meet
        // by accident.
        SiteMenuAction.repaint =>
          hostIsAndroid && DeveloperModeService.instance.enabled
              ? (Icons.format_paint, loc.commonRepaintScreen)
              : null,
        SiteMenuAction.settings => (Icons.settings, loc.homeSettingsMenu),
        SiteMenuAction.devTools => (Icons.code, loc.homeDeveloperToolsMenu),
        SiteMenuAction.addToHome => state.offersShortcut
            ? (Icons.add_to_home_screen, loc.homeHomeShortcutMenu)
            : null,
      };

  PopupMenuItem<SiteMenuAction> _navRow(
    BuildContext menuContext, {
    required AppLocalizations loc,
    required bool loading,
  }) {
    void close(VoidCallback then) {
      Navigator.pop(menuContext);
      then();
    }

    final duplicateTab = nav.duplicateTab;
    return PopupMenuItem(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back),
            tooltip: loc.homeGoBackTooltip,
            onPressed: () => close(nav.back),
          ),
          IconButton(
            icon: Icon(Icons.home),
            tooltip: loc.homeGoToHomeTooltip,
            onPressed: () => close(nav.home),
          ),
          IconButton(
            icon: Icon(Icons.share),
            tooltip: loc.commonShare,
            onPressed: () => close(nav.share),
          ),
          IconButton(
            icon: Icon(loading ? Icons.close : Icons.refresh),
            tooltip: loading ? loc.homeStopTooltip : loc.homeRefreshTooltip,
            onLongPress:
                duplicateTab == null ? null : () => close(duplicateTab),
            onPressed: () => close(loading ? nav.stop : nav.reload),
          ),
        ],
      ),
    );
  }
}
