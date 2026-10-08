import Foundation

/// The App Group the app, its share extension and its App Intents hand data
/// through, and the keys they hand it under. Compiled into all four Apple
/// targets (both Runners, both share extensions) from this one file.
enum AppGroup {
  #if os(macOS)
    /// A sandboxed macOS app addresses its group by the team-prefixed id.
    /// Spelled out rather than built from `$(TeamIdentifierPrefix)`: the
    /// release build has no team until `scripts/sign_macos.sh` signs it, so a
    /// build-time prefix would come out empty (docs/releasing-macos.md).
    static let id = "7NGC2P87LM.group.org.codeberg.theoden8.webspace"
  #else
    static let id = "group.org.codeberg.theoden8.webspace"
  #endif

  /// Nil when the build carries no App Group entitlement (an unsigned or
  /// ad-hoc build).
  static var defaults: UserDefaults? { UserDefaults(suiteName: id) }

  /// A URL the share extension hands the app (LIR-004).
  static let pendingShareUrlKey = "pending_share_url"

  /// An HTML document the iOS share extension hands the app (LIR-012): the
  /// body as a file in the group container, its title and source in defaults.
  static let pendingShareHtmlFile = "pending_share.html"
  static let pendingShareHtmlTitleKey = "pending_share_html_title"
  static let pendingShareHtmlSourceKey = "pending_share_html_source"

  /// JSON `[{id, name, url}]` of the live sites, written by
  /// `ShortcutsPlugin.syncSites` for the App Intents site picker.
  static let shortcutSitesKey = "shortcut_sites"

  /// The same for recently deleted sites: never offered in the picker, but
  /// resolved by `entities(for:)` so a Shortcut bound to one still runs and
  /// routes by domain on the Dart side (HS-011).
  static let shortcutTombstonesKey = "shortcut_tombstones"

  /// The site an `OpenSiteIntent` resolved, and its url so a deleted site can
  /// route by domain (HS-011). Drained together by
  /// `ShortcutsPlugin.getLaunchSiteId`.
  static let pendingShortcutSiteIdKey = "pending_shortcut_site_id"
  static let pendingShortcutUrlKey = "pending_shortcut_url"
}
