/// Where a cross-domain link a site opens goes (NESTED-009). A link to a
/// domain the site claims stays in the app whatever the mode says.
///
/// - [inApp]: a nested screen over the site, with the site's own settings and
///   container. Outbound routing (LIR-014) is an option of this mode only.
/// - [browser]: the device's default browser.
/// - [block]: nowhere; the navigation is cancelled. Only top-level
///   navigations reach the decision, so images, scripts and frames from other
///   domains still load.
enum ExternalLinkMode { inApp, browser, block }

/// Parse a stored mode name. [legacyInBrowser] is the `externalLinksInBrowser`
/// bool this field replaced, read only when no mode is stored.
ExternalLinkMode externalLinkModeFromJson(
    Object? modeName, Object? legacyInBrowser) {
  if (modeName is String) {
    for (final m in ExternalLinkMode.values) {
      if (m.name == modeName) return m;
    }
  }
  return legacyInBrowser == true
      ? ExternalLinkMode.browser
      : ExternalLinkMode.inApp;
}
