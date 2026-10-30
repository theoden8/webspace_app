import 'package:webspace/settings/capture.dart';

/// Whether a site's QR share carries a field (QR-001): the site's
/// configuration does; its session, device-local ids, trust given on one
/// device and bytes that would blow the code's capacity do not.
enum QrShare { carried, withheld }

/// Every value a site's JSON carries, under the key it is saved by, in the
/// order a save writes them. A save, a read and a QR share each go through
/// this list, so a field added here does not compile until the save and the
/// read answer it, and it says whether a QR carries it.
enum SiteField {
  siteId('siteId', qr: QrShare.withheld),
  initUrl('initUrl', qr: QrShare.carried),
  currentUrl('currentUrl', qr: QrShare.withheld),
  // Session, not configuration (TAB-009).
  tabs('tabs', qr: QrShare.withheld),
  name('name', qr: QrShare.carried),
  pageTitle('pageTitle', qr: QrShare.withheld),
  cookies('cookies', qr: QrShare.withheld),
  proxySettings('proxySettings', qr: QrShare.carried),
  javascriptEnabled('javascriptEnabled', qr: QrShare.carried),
  userAgent('userAgent', qr: QrShare.carried),
  // A read recovers it from the user agent it rendered.
  uaPreset('uaPreset', qr: QrShare.withheld),
  thirdPartyCookiesEnabled('thirdPartyCookiesEnabled', qr: QrShare.carried),
  httpsUpgradeEnabled('httpsUpgradeEnabled', qr: QrShare.carried),
  incognito('incognito', qr: QrShare.carried),
  alwaysOpenHome('alwaysOpenHome', qr: QrShare.carried),
  kioskMode('kioskMode', qr: QrShare.carried),
  tabsEnabled('tabsEnabled', qr: QrShare.carried),
  signInPopups('signInPopups', qr: QrShare.carried),
  // A scanned site is a new container, which gets its own colour (TAB-018).
  containerColor('containerColor', qr: QrShare.withheld),
  language('language', qr: QrShare.carried),
  zoomPercent('zoomPercent', qr: QrShare.carried),
  theme('theme', qr: QrShare.carried),
  clearUrlEnabled('clearUrlEnabled', qr: QrShare.carried),
  dnsBlockEnabled('dnsBlockEnabled', qr: QrShare.carried),
  dnsBlockLevel('dnsBlockLevel', qr: QrShare.carried),
  disabledFilterLists('disabledFilterLists', qr: QrShare.carried),
  contentBlockEnabled('contentBlockEnabled', qr: QrShare.carried),
  trackingProtectionEnabled('trackingProtectionEnabled', qr: QrShare.carried),
  lockdownModeEnabled('lockdownModeEnabled', qr: QrShare.carried),
  localCdnEnabled('localCdnEnabled', qr: QrShare.carried),
  // Never shared so far: sharing it is its own decision.
  externalLinkMode('externalLinkMode',
      qr: QrShare.withheld, legacyKeys: ['externalLinksInBrowser']),
  fullscreenMode('fullscreenMode', qr: QrShare.carried),
  blockScreenshots('blockScreenshots', qr: QrShare.carried),
  // Never shared so far: sharing it is its own decision.
  tabBarButtonCorner('tabBarButtonCorner',
      qr: QrShare.withheld, legacyKeys: ['tabBarButtonOnRight']),
  htmlCachingEnabled('htmlCachingEnabled', qr: QrShare.carried),
  notificationsEnabled('notificationsEnabled',
      qr: QrShare.carried, legacyKeys: ['backgroundPoll']),
  backgroundAudioEnabled('backgroundAudioEnabled', qr: QrShare.carried),
  // A remembered decision is trust given one device's prompt.
  protectedContentAllowed('protectedContentAllowed', qr: QrShare.withheld),
  // Each capture kind's own keys, which [keys] names; the virtual sources
  // are local media that would also blow QR capacity.
  captures('captures', qr: QrShare.withheld),
  userScripts('userScripts', qr: QrShare.withheld),
  enabledGlobalScriptIds('enabledGlobalScriptIds', qr: QrShare.withheld),
  // Ids from this device's extension library (WEBEXT-011). Builds before
  // the per-extension default saved the set switched on (WEBEXT-004).
  webExtensionChoices('webExtensionChoices',
      qr: QrShare.withheld, legacyKeys: ['enabledWebExtensions']),
  blockedCookies('blockedCookies', qr: QrShare.withheld),
  locationMode('locationMode', qr: QrShare.carried),
  spoofLatitude('spoofLatitude', qr: QrShare.carried),
  spoofLongitude('spoofLongitude', qr: QrShare.carried),
  spoofAccuracy('spoofAccuracy', qr: QrShare.carried),
  spoofTimezone('spoofTimezone', qr: QrShare.carried),
  spoofTimezoneFromLocation('spoofTimezoneFromLocation', qr: QrShare.carried),
  liveLocationGranularity('liveLocationGranularity', qr: QrShare.carried),
  webRtcPolicy('webRtcPolicy', qr: QrShare.carried),
  // Never shared so far: sharing them is its own decision.
  letterboxEnabled('letterboxEnabled', qr: QrShare.withheld),
  spoofWindowWidth('spoofWindowWidth', qr: QrShare.withheld),
  spoofWindowHeight('spoofWindowHeight', qr: QrShare.withheld),
  // The seed that makes this site's fingerprint differ from every other
  // device's.
  fingerprintResetNonce('fingerprintResetNonce', qr: QrShare.withheld),
  // Base64 PNG bytes: device-local cosmetics, and too big for a QR.
  customIconPng('customIconPng', qr: QrShare.withheld),
  // A scanned code must not make a site claim domains: claims decide where
  // other sites' links and shared URLs go.
  domainClaims('domainClaims', qr: QrShare.withheld),
  // Whether a redirected domain was already offered is local prompt history.
  offeredRedirectDomains('offeredRedirectDomains', qr: QrShare.withheld),
  routeOutboundLinks('routeOutboundLinks', qr: QrShare.carried),
  // Each entry names a device-local siteId (QR-003).
  outboundPreferences('outboundPreferences', qr: QrShare.withheld),
  // How to search the site: configuration, no site ids (LIR-031).
  searchAddress('searchAddress', qr: QrShare.carried),
  searchesWeb('searchesWeb', qr: QrShare.carried),
  // Learned from the site's own pages; the receiver's copy learns it the
  // same way (LIR-035).
  discoveredSearchAddress('discoveredSearchAddress', qr: QrShare.withheld),
  discoveredSearchesWeb('discoveredSearchesWeb', qr: QrShare.withheld),
  // Device-local site ids (QR-003).
  searchSites('searchSites', qr: QrShare.withheld),
  searchDefault('searchDefault', qr: QrShare.withheld);

  const SiteField(this.key, {required this.qr, this.legacyKeys = const []});

  /// The key a save writes. [captures] names its group with it and writes
  /// each kind's own keys instead.
  final String key;

  final QrShare qr;

  /// Older names a read still takes and a save no longer writes.
  final List<String> legacyKeys;

  /// Every key a save may write for this field.
  List<String> get keys => this == captures
      ? [for (final kind in CaptureKind.values) ...kind.jsonKeys]
      : [key];

  /// Every older key a read still takes for this field.
  List<String> get oldKeys => this == captures
      ? [for (final kind in CaptureKind.values) ?kind.legacyAllowedKey]
      : legacyKeys;
}
