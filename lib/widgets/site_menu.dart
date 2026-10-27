import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/shortcut_label.dart';

/// What a site's overflow menu offers, in menu order.
enum SiteMenuAction {
  newTab,
  backToWebspaces,
  search,
  toggleUrlBar,
  fullscreen,
  repaint,
  settings,
  devTools,
  addToHome,
}

/// Where a site's overflow menu sits: the app bar, or the end of the tab
/// strip while the strip is on.
enum SiteMenuPlacement { appBar, tabStrip }

/// What the menu shows for the site on screen, read when it opens.
typedef SiteMenuState = ({
  bool loading,
  bool tabsOn,
  bool fullscreen,
  bool offersShortcut,
});

/// The buttons of a webview menu's top row. Each closes the menu, then acts.
typedef SiteMenuNav = ({
  VoidCallback back,

  /// Null on a screen with no home of its own, a nested one.
  VoidCallback? home,
  VoidCallback share,
  VoidCallback reload,
  VoidCallback stop,

  /// A long press on back, where the site has tabs (TAB-020).
  VoidCallback? backInNewTab,

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
        SiteMenuPlacement.tabStrip => PopupMenuButton<SiteMenuAction>(
            icon: Icon(Icons.more_vert, size: 20),
            padding: EdgeInsets.zero,
            tooltip: AppLocalizations.of(context).homeMenuTooltip,
            itemBuilder: _items,
            onSelected: onSelected,
          ),
      };

  List<PopupMenuEntry<SiteMenuAction>> _items(BuildContext menuContext) {
    final loc = AppLocalizations.of(menuContext);
    final names = MaterialLocalizations.of(menuContext);
    final s = state();
    return [
      siteMenuNavRow(menuContext, nav: nav, loading: s.loading),
      PopupMenuDivider(),
      for (final action in SiteMenuAction.values)
        if (_entry(action, state: s, loc: loc, names: names)
            case (final icon, final label, final keys))
          PopupMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(icon),
                SizedBox(width: 8),
                if (keys != null) ...[
                  Expanded(child: Text(label)),
                  SizedBox(width: Spacing.xl),
                  ShortcutKeys(keys),
                ] else
                  Flexible(child: Text(label)),
              ],
            ),
          ),
    ];
  }

  /// Icon, label and desktop key (NAV-014) of [action] in this menu, or null
  /// where it does not offer it.
  (IconData, String, String?)? _entry(
    SiteMenuAction action, {
    required SiteMenuState state,
    required AppLocalizations loc,
    required MaterialLocalizations names,
  }) =>
      switch (action) {
        SiteMenuAction.newTab => state.tabsOn
            ? (Icons.add, loc.tabsNewTab, shortcutLabel<OpenNewTab>(names))
            : null,
        SiteMenuAction.backToWebspaces =>
          placement == SiteMenuPlacement.tabStrip
              ? (Icons.arrow_back, loc.homeBackToWebspaces, null)
              : null,
        SiteMenuAction.search =>
          (Icons.search, loc.homeFindMenu, shortcutLabel<FindInPage>(names)),
        SiteMenuAction.toggleUrlBar => AppPref.showUrlBar.value
            ? (Icons.visibility_off, loc.homeHideUrlBarMenu, null)
            : (Icons.visibility, loc.homeShowUrlBarMenu, null),
        SiteMenuAction.fullscreen => state.fullscreen
            ? (Icons.fullscreen_exit, loc.homeExitFullScreenMenu, null)
            : (Icons.fullscreen, loc.homeFullScreenMenu, null),
        // Manual escape hatch for the recurring Android blank surface
        // (BUG-001 / PAUSE-028): every automatic trigger is an enumerated
        // code path, and the user is the only one who can see a path nobody
        // enumerated. Android-only, where the nudge is not a no-op, and
        // behind developer mode: it is a diagnostic, not something to meet
        // by accident.
        SiteMenuAction.repaint =>
          hostIsAndroid && DeveloperModeService.instance.enabled
              ? (Icons.format_paint, loc.commonRepaintScreen, null)
              : null,
        SiteMenuAction.settings => (Icons.settings, loc.homeSettingsMenu, null),
        SiteMenuAction.devTools => (Icons.code, loc.homeDeveloperToolsMenu, null),
        SiteMenuAction.addToHome => state.offersShortcut
            ? (Icons.add_to_home_screen, loc.homeHomeShortcutMenu, null)
            : null,
      };
}

/// A webview menu's top row: back, home, share, and reload or stop while the
/// page is [loading]. The site menu and the nested screen's share it, so the
/// same buttons sit in the same place in both.
PopupMenuItem<T> siteMenuNavRow<T>(
  BuildContext menuContext, {
  required SiteMenuNav nav,
  required bool loading,
}) {
  final loc = AppLocalizations.of(menuContext);
  final names = MaterialLocalizations.of(menuContext);

  void close(VoidCallback then) {
    Navigator.pop(menuContext);
    then();
  }

  final backInNewTab = nav.backInNewTab;
  final duplicateTab = nav.duplicateTab;
  return PopupMenuItem(
    padding: EdgeInsets.zero,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(Icons.arrow_back),
          tooltip: shortcutTooltip<GoBack>(loc.homeGoBackTooltip, names: names),
          onLongPress:
              backInNewTab == null ? null : () => close(backInNewTab),
          onPressed: () => close(nav.back),
        ),
        if (nav.home case final home?)
          IconButton(
            icon: Icon(Icons.home),
            tooltip: loc.homeGoToHomeTooltip,
            onPressed: () => close(home),
          ),
        IconButton(
          icon: Icon(Icons.share),
          tooltip: loc.commonShare,
          onPressed: () => close(nav.share),
        ),
        IconButton(
          icon: Icon(loading ? Icons.close : Icons.refresh),
          tooltip: loading
              ? loc.homeStopTooltip
              : shortcutTooltip<ReloadPage>(loc.homeRefreshTooltip,
                  names: names),
          onLongPress:
              duplicateTab == null ? null : () => close(duplicateTab),
          onPressed: () => close(loading ? nav.stop : nav.reload),
        ),
      ],
    ),
  );
}
