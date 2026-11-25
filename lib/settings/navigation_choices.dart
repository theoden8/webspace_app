// The site navigation choices as plain values, read by the engines that
// decide what shows; the app's current ones are in site_navigation.dart.

/// How the sites and their tabs are reached beside the app bar's tab-count
/// button: the site strip or the sidebar, never both. Where the one control
/// rests says which (TAB-038): the sidebar's arrow tab on the left edge, the
/// strip's button over the page.
enum SiteNavigation {
  strip,
  sidebar;

  /// The value [raw] names; anything else, the default. An earlier build's
  /// `tabButton` is read by `loadSiteNavigation`, which also hides the
  /// sidebar.
  static SiteNavigation parse(String raw) =>
      values.asNameMap()[raw] ?? sidebar;
}

/// What full screen does with the strip or the sidebar: hides it, or leaves
/// its control, which brings it back over the page.
enum FullscreenNavigation {
  hidden,
  button;

  /// The value [raw] names; anything else, an earlier build's `kept`
  /// among them, the button.
  static FullscreenNavigation parse(String raw) =>
      values.asNameMap()[raw] ?? button;
}

/// The sidebar's state, one for the app: open, collapsed to a rail, hidden.
enum SidebarState {
  open,
  collapsed,
  hidden;

  /// The value [raw] names; anything else, the default.
  static SidebarState parse(String raw) => values.asNameMap()[raw] ?? open;
}

/// What the open sidebar shows: the sites as squares, their tabs opening
/// out under them, or the tab tree.
enum SidebarStyle {
  squares,
  tree;

  /// The value [raw] names; anything else, the default.
  static SidebarStyle parse(String raw) => values.asNameMap()[raw] ?? squares;
}
