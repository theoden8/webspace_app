import 'dart:async';
import 'dart:convert' show base64Decode, base64Encode;
import 'package:webspace/platform/host_platform.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show CookieManager, WebUri;
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/link_routing_service.dart' show LinkRoutingService;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/media_session_shim.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/opensearch_engine.dart'
    show DiscoveredSearch, SiteSearchTarget;
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/user_agent_preset.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/blocked_cookie.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/url_host.dart';

export 'package:webspace/services/url_host.dart'
    show extractDomain, getBaseDomain, getNormalizedDomain;
export 'package:webspace/settings/blocked_cookie.dart';
export 'package:webspace/settings/location.dart'
    show LocationMode, LocationGranularity, WebRtcPolicy;

/// Per-site page-zoom bounds (percent). Mirrors the range desktop browsers
/// expose; 100 is unscaled.
const int kMinZoomPercent = 30;
const int kMaxZoomPercent = 300;
const int kDefaultZoomPercent = 100;

int clampZoomPercent(int value) =>
    value.clamp(kMinZoomPercent, kMaxZoomPercent);

class ConsoleLogEntry {
  final DateTime timestamp;
  final String message;
  final ConsoleMessageLevel level;
  final bool isEvalInput;

  ConsoleLogEntry({
    required this.timestamp,
    required this.message,
    required this.level,
    this.isEvalInput = false,
  });
}


/// Generates a unique site ID for per-site cookie isolation.
String _generateSiteId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final random = Random().nextInt(999999);
  final id = '${now.toRadixString(36)}-${random.toRadixString(36)}';
  assert(_kSiteIdPattern.hasMatch(id), 'a minted siteId is path-safe');
  return id;
}

/// A siteId is concatenated into filesystem paths (HTML/import/nav-state cache
/// filenames, native container names) and secure-storage keys, so an imported
/// backup must not smuggle path metacharacters. Accept only a path-safe token;
/// anything else (including `../…` traversal) returns null so the caller mints
/// a fresh id.
final RegExp _kSiteIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

String? sanitizedSiteId(Object? raw) {
  if (raw is! String) return null;
  return _kSiteIdPattern.hasMatch(raw) ? raw : null;
}

/// The per-site `language` is a constrained dropdown in the UI, but an
/// imported backup or scanned QR can carry an arbitrary string. It is
/// interpolated raw into the `Accept-Language` request header, so a value
/// with CRLF could smuggle extra headers into the site's requests. Accept
/// only a BCP-47-shaped tag (`en`, `zh-CN`, …); anything else returns null
/// (system default), matching the siteId hardening.
final RegExp _kLanguageTagPattern =
    RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

String? sanitizedLanguageTag(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return _kLanguageTagPattern.hasMatch(raw) ? raw : null;
}

/// Generates a fresh per-site fingerprint reset nonce. Uses [Random.secure]
/// so a site can't predict the post-reset fingerprint.
String generateFingerprintResetNonce() {
  final rng = Random.secure();
  final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Opens [url] in a nested `InAppWebViewScreen` that runs as the opening
/// site, under [posture] (see [SitePosture], which a new per-site field joins
/// rather than this signature). Implemented by `_WebSpacePageState.launchUrl`.
typedef LaunchUrlFunc = void Function(
  String url,
  SitePosture posture, {
  String? homeTitle,
});

/// Interpret a renderer-health probe result. The probe reads
/// `document.body.offsetHeight`: a live renderer returns a number — `0`
/// (about:blank), `-1` (document/body not built yet, still loading), or a
/// positive height. A dead renderer (iOS content-process jettisoned,
/// Android renderer killed) makes `evaluateJavascript` throw, surfaced as a
/// `null` result by [WebViewController.evaluateJavascriptReturning]. Only
/// `null` means gone; every numeric value is alive.
bool rendererProbeIndicatesGone(Object? probeResult) => probeResult == null;

class WebViewModel implements MediaGrantRecord {
  final String siteId; // Unique ID for per-site cookie isolation
  String initUrl; // Made non-final to allow URL editing

  /// This site's tabs, in tree order (a child follows its parent). Never
  /// empty. Exactly one of them — [activeTabId] — is bound to the site's
  /// single webview; the rest are parked and hold no renderer. See
  /// [lib/services/site_tab.dart] and TAB-001/TAB-002.
  late List<SiteTab> tabs;

  /// The tab the site's webview is showing. Always names a member of [tabs].
  late String activeTabId;

  SiteTab get activeTab {
    final tab = tabs.where((t) => t.id == activeTabId).firstOrNull;
    assert(tab != null, 'activeTabId $activeTabId is not among the tabs');
    return tab ?? tabs.first;
  }

  /// The URL this site is showing: the active tab's. A setter rather than a
  /// field so every existing `model.currentUrl = …` writer keeps working and
  /// writes to whichever tab is on screen.
  String get currentUrl => activeTab.url;
  set currentUrl(String value) => activeTab.url = value;

  String? get pageTitle => activeTab.title;
  set pageTitle(String? value) => activeTab.title = value;

  /// Resolves a siteId to its model, so a tab hosted by another site can find
  /// that site (LIR-018). Set once by the page that owns the site list.
  static WebViewModel? Function(String siteId)? siteLookup;

  /// Set by the page: a link in a hosted tab that leads back into this site's
  /// own domain opens as this site's child tab (S6 of the web search design).
  void Function(String url)? onReturnToOwner;

  /// The site [tab] runs as when that is not this one, or null.
  WebViewModel? hostOf(SiteTab tab) {
    final id = tab.hostSiteId;
    return id == null ? null : siteLookup?.call(id);
  }

  /// The site this slot runs as (LIR-018): the host of the active tab, or
  /// this site. The slot itself — the webview, controller, loading state and
  /// the tab records — stays this site's.
  WebViewModel get runningIdentity => hostOf(activeTab) ?? this;

  bool get runsHostedTab => activeTab.hostSiteId != null;

  /// The active tab names a host that is not there. The tab must close rather
  /// than load its host's URL as this site (LIR-023).
  bool get activeHostMissing => runsHostedTab && hostOf(activeTab) == null;

  /// Whether [tab] runs outside the domain of the site it runs as (LIR-034):
  /// a tab a link opened while its opener's routing was off, which runs as the
  /// opener inside the link's domain. Its container and posture are the site
  /// it runs as; the domain it navigates in is its [SiteTab.homeUrl]'s.
  bool isForeignTab(SiteTab tab) {
    final home = tab.homeUrl;
    if (home == null) return false;
    final identity = hostOf(tab) ?? this;
    return getNormalizedDomain(home) != getNormalizedDomain(identity.initUrl);
  }

  bool get runsForeignTab => isForeignTab(activeTab);

  /// Where the active tab's domain is anchored, and where Home (NAV-004) takes
  /// it: a foreign tab's home, else the home page of the site it runs as.
  String get navigationHomeUrl =>
      runsForeignTab ? activeTab.homeUrl! : runningIdentity.initUrl;

  /// The claims the active tab navigates by. A foreign tab borrows none from
  /// the site it runs as: only the link's own domain stays in place.
  bool navigationMatchesClaim(String url) =>
      !runsForeignTab && runningIdentity.matchesSiteClaim(url);

  /// Storage key for the active tab's `controller.saveState()` bytes. State is
  /// per tab, not per site: switching tabs captures under the outgoing tab's
  /// key and restores from the incoming one's (TAB-003). Keyed by the site the
  /// tab runs as (LIR-022), so wiping that site drops them.
  String get activeStateKey => stateKeyForTab(activeTabId);

  String stateKeyForTab(String tabId) {
    final tab = tabs.where((t) => t.id == tabId).firstOrNull;
    return webViewStateKey(tab?.hostSiteId ?? siteId, tabId);
  }

  /// Whether the active tab's back stack may be written (LIR-022): its record
  /// persists with this site's tab list, and the site it runs as keeps state.
  bool get activeTabPersistsNavState {
    if (!persistsNavState) return false;
    if (!runsHostedTab) return true;
    final host = hostOf(activeTab);
    return host != null && host.persistsNavState;
  }

  /// Whether [tabs] is still exactly what a site that never opened a second
  /// tab carries. Serialisation omits the list while this holds, so on-disk
  /// output is unchanged for those users (same rule as `domainClaims`).
  bool get tabsAreDefault =>
      tabs.length == 1 &&
      tabs.single.id == kPrimaryTabId &&
      tabs.single.parentId == null;

  /// The user's per-site Tabs choice (TAB-013). Read [effectiveTabsEnabled]
  /// instead: a kiosk site runs as one page whatever this stores, and the
  /// stored value comes back when Kiosk mode is turned off.
  bool tabsEnabled;

  /// A kiosk site runs as one page, never with tabs (TAB-013). Turning tabs
  /// off this way keeps the tab list, as the app-wide switch does (TAB-012).
  bool get effectiveTabsEnabled =>
      resolveTabs(tabs: tabsEnabled, kiosk: kioskMode);

  /// The colour this site's container is drawn in, as an index into the
  /// container palette (TAB-018). Given once, when the site first needs one,
  /// and kept; null until then.
  int? containerColor;

  /// Put a site that has no webview yet on a tab at its home page, as Always
  /// open Home asks of every fresh entry (TAB-014). With tabs the tab it was on
  /// stays in the list; without, that tab is sent home, as before tabs.
  void landAtHome({required bool tabsOn}) {
    if (tabsOn) {
      final landing =
          TabLifecycleEngine.homeLanding(tabs, activeTabId, initUrl);
      if (landing == null) return;
      tabs = landing.tabs;
      activeTabId = landing.activeTabId;
      return;
    }
    bindOwnerRunTab();
    if (currentUrl == initUrl) return;
    currentUrl = initUrl;
    pageTitle = null;
  }

  /// LIR-018: before an owner URL loads, move a site with no live webview from
  /// a hosted tab to one it runs itself: the nearest such ancestor, or a new
  /// root tab at home. A live slot moves through a tab switch instead.
  void bindOwnerRunTab() {
    if (!runsHostedTab && !runsForeignTab) return;
    final id = TabLifecycleEngine.ownerRunTab(tabs, activeTabId,
        isForeign: isForeignTab);
    if (id != null) {
      activeTabId = id;
    } else {
      final tab = SiteTab(url: initUrl);
      tabs = [...tabs, tab];
      activeTabId = tab.id;
    }
    activeTab.lastActiveAt = DateTime.now();
  }

  String name; // Custom name for the site
  List<Cookie> cookies;
  Widget? webview;
  /// Destination of the last main-frame navigation this site's webview
  /// refused to make because the app could not establish that it would go
  /// through the site's proxy (LEAK-010). Drives the interstitial over the
  /// page; deliberately not persisted, since it describes one navigation and
  /// not the site.
  String? blockedNavigationUrl;
  WebViewController? controller;
  UserProxySettings proxySettings;
  bool javascriptEnabled;
  String userAgent;
  /// Which generated UA shape [userAgent] was rendered from, or null for
  /// a free-text custom string (or no override). When set, webviews are
  /// built from [effectiveUserAgent] — a fresh render at the current
  /// Firefox version — so builder fixes and version refreshes reach
  /// every site without a stored-string migration.
  UserAgentPreset? uaPreset;
  bool thirdPartyCookiesEnabled;
  /// HTTPS-005: null follows the app-wide `httpsUpgradeEnabled` default. Set
  /// explicitly only for a site the user has decided has no TLS.
  bool? httpsUpgradeEnabled;
  bool incognito; // Private browsing mode - no cookies/cache persist
  /// When true, the site's currentUrl/pageTitle are not persisted: every
  /// app restart and every Android home-shortcut tap returns the site to
  /// its `initUrl`. Cookies / localStorage / IDB ARE preserved (the user
  /// keeps their login session); only the navigation URL resets. Implied
  /// by [incognito], which adds the cookie/storage wipe on top.
  bool alwaysOpenHome;
  /// When true and the site is launched via a home-screen shortcut, the app
  /// shell opens chrome-less: no drawer, tab strip, app-bar actions, or
  /// context menus, so the site can't be reconfigured, deleted, or navigated
  /// away from. Opening the app normally (launcher icon, no shortcut) restores
  /// full access. Pure UI state, derived at launch; never gates the webview
  /// engine, so it is not threaded through WebViewConfig / nested screens.
  bool kioskMode;
  String? language; // Language code (e.g., 'en', 'es'), null = system default
  /// Browser-style page zoom for this site, as a percent (100 = unscaled).
  /// Scales the whole page (text and images) via CSS `zoom`, independent of
  /// the OS accessibility font scale that [WebViewController.setTextZoom]
  /// tracks. Clamped to [kMinZoomPercent]..[kMaxZoomPercent].
  int zoomPercent;
  bool clearUrlEnabled; // Strip tracking parameters from URLs via ClearURLs
  bool dnsBlockEnabled; // Block navigation to domains on Hagezi DNS blocklist

  /// Hagezi severity level this site blocks at, or null to follow the
  /// app-wide level. A level only takes effect once its list has been
  /// downloaded — see `DnsBlockService.effectiveLevelFor`.
  int? dnsBlockLevel;
  bool contentBlockEnabled; // Block ads/trackers via ABP filter list rules

  /// Filter lists this site opts out of, by list id. A mask over the
  /// app-wide selection: a list not enabled globally is not in the engine at
  /// all, so naming it here does nothing.
  Set<String> disabledFilterLists;

  /// Both blocker masks are dropped for archive-tier sites (ARCH-006). Each
  /// leaves a trace outside the archive's keyspace whose presence would
  /// betray that an archive exists: a per-site level pins a downloaded level
  /// file, and a per-site list selection rewrites the shared engine cache
  /// blob. Archive sites run the app-wide posture instead.
  int? get effectiveDnsBlockLevel =>
      ArchiveFold.dnsBlockLevel(dnsBlockLevel, archived: isArchiveTier);

  Set<String> get effectiveDisabledFilterLists => ArchiveFold.disabledFilterLists(
      disabledFilterLists, archived: isArchiveTier);
  /// Umbrella per-site Enhanced Tracking Protection: when true, applies
  /// the anti-fingerprinting JS shim (Canvas/WebGL/audio/fonts/screen/
  /// hardware/timing) AND forces clearUrlEnabled, dnsBlockEnabled, and
  /// contentBlockEnabled to behave as on regardless of their own value.
  /// When false, the three sub-toggles act independently as before.
  bool trackingProtectionEnabled;
  bool localCdnEnabled; // Serve CDN resources from local cache for privacy
  /// Where a cross-domain link that is not covered by this site's domain
  /// claims goes: a nested in-app webview (the default), the system browser
  /// (discussion #438) or nowhere (issue #629). Links to claimed domains
  /// open in-app in every mode.
  ExternalLinkMode externalLinkMode;
  bool fullscreenMode; // Auto-enter fullscreen when this site is selected
  /// While this site is on screen, the window is withheld from screenshots,
  /// recordings and the recent-apps preview (SCREENBLOCK-002). Android only;
  /// the value is kept elsewhere so a backup restored there still carries it.
  bool blockScreenshots;
  /// Corner the floating tab-bar button rests in while this site is
  /// active. Set by dragging the button itself; null = never dragged,
  /// falls back to the app-wide default.
  TabBarCorner? tabBarButtonCorner;
  /// When true, the cached HTML snapshot is rendered as `initialData` for
  /// instant first paint on construction, then swapped to a live load
  /// once the cached parse settles. When false, the cached snapshot is
  /// only used as a fallback when the device is offline at construction
  /// time — online cold starts go straight to live. Saves to the cache
  /// happen regardless so the offline fallback keeps working.
  bool htmlCachingEnabled;
  /// Allow this site to show system notifications. Implies background
  /// polling: the site is auto-loaded on startup, kept resident across
  /// site switches and app-lifecycle pauses, and reloaded periodically by
  /// the foreground poll timer so it can detect new content and fire
  /// notifications even when the user isn't looking at it.
  bool notificationsEnabled;
  /// Keep this site's audio playing when it is not the visible site or the
  /// app is backgrounded. Exempts the site from the per-instance pause on
  /// site switch (iOS's alert-hack pause would freeze the page's JS thread
  /// and stall any streaming player) and, while any such site is loaded,
  /// from the process-global JS-timer pause on app background (Android's
  /// `pauseTimers()` is global and would starve MSE/streaming players).
  /// On iOS this additionally activates the `.playback` AVAudioSession so
  /// playback survives backgrounding (paired with the `audio`
  /// UIBackgroundModes entry).
  bool backgroundAudioEnabled;
  /// Remembered per-site decision for protected (DRM/Widevine EME) content,
  /// e.g. the Spotify web player. null = not yet decided (the webview shows
  /// an Allow/Block popup on the first `PROTECTED_MEDIA_ID` permission
  /// request); true = grant silently; false = deny silently. Granting lets
  /// the origin provision a Widevine device identifier, so the default is
  /// "ask" rather than always-on. Android-only: WKWebView (iOS/macOS) has no
  /// EME/Widevine support and never issues this request.
  @override
  bool? protectedContentAllowed;
  /// Remembered per-site camera, microphone and screen-sharing decisions,
  /// with the file each `virtual` mode serves. An untouched kind asks on the
  /// first request. Only user intent is stored: Android's app-level CAMERA
  /// permission is re-checked at every real grant, so an OS-level denial is
  /// never frozen into a per-site Block.
  @override
  CaptureGrants captures;
  List<UserScriptConfig> userScripts; // Per-site user scripts
  /// IDs of global user scripts opted into for this site. Global scripts
  /// are stored once in app state (shared source/URL) and each site
  /// independently enables which ones to inject.
  Set<String> enabledGlobalScriptIds;
  Set<BlockedCookie> blockedCookies; // Per-site blocked cookies (name + domain)
  LocationMode locationMode;
  double? spoofLatitude;
  double? spoofLongitude;
  /// Coordinate accuracy in meters reported to the spoofed Position.
  double spoofAccuracy;
  /// IANA timezone name to expose via [Intl.DateTimeFormat] and
  /// [Date.prototype.getTimezoneOffset]. Null leaves the real zone. Holds
  /// the effective zone, a "From picked location" one included, so every
  /// webview applies this and nothing else.
  String? spoofTimezone;
  /// The user picked "From picked location" rather than a zone. The zone is
  /// resolved from the coordinates where the polygon dataset is loaded (at
  /// settings save, and for a site saved before that on startup; Tracking
  /// Protection forces it when coordinates are set, see
  /// `derivesTimezoneFromLocation`) and stored in [spoofTimezone]. A UI and
  /// re-resolution marker only: no webview reads it.
  bool spoofTimezoneFromLocation;
  /// Granularity applied to the real GPS fix surfaced by
  /// [LocationMode.live]. [LocationGranularity.gps] (default) reports
  /// the raw device coords. [LocationGranularity.approximate] snaps to
  /// a ~110 m grid while still using the GPS provider so a fix actually
  /// arrives. [LocationGranularity.gsm] uses the network provider only
  /// and snaps to a ~1.1 km grid. Ignored for [LocationMode.off] and
  /// [LocationMode.spoof].
  LocationGranularity liveLocationGranularity;
  WebRtcPolicy webRtcPolicy;
  /// User-set window content size reported to the page by the
  /// anti-fingerprinting shim (`window.innerWidth`/`innerHeight`). Both must
  /// be set and positive to take effect; when either is null the shim picks
  /// a stable, plausible desktop window size seeded by [siteId]. Only applied
  /// when [trackingProtectionEnabled] is on, since the shim is gated on it.
  /// When true, the site's WebView is rendered in a Tor-style letterbox: a
  /// centered box snapped to a 200x100 grid of the available area (or exactly
  /// [spoofWindowWidth] x [spoofWindowHeight] when both are set), with margin
  /// bars. The reported viewport is bucketed and `screen.*` mirrors the real
  /// `window.inner*`. Only active under [trackingProtectionEnabled].
  bool letterboxEnabled;
  /// Exact content-box size for letterbox mode. Both must be set and positive;
  /// otherwise the box snaps to the grid of the available area.
  int? spoofWindowWidth;
  int? spoofWindowHeight;
  /// Per-site nonce mixed into the anti-fingerprinting seed, regenerated when
  /// the user clears this site's data so the fingerprint (canvas/WebGL/audio/
  /// window size/…) rerolls and the site can't re-identify the user across a
  /// reset. Null until the first reset, so existing sites keep their
  /// fingerprint on upgrade. Regenerate via [rerollFingerprint].
  String? fingerprintResetNonce;

  /// User-chosen icon for this site, normalized to PNG (longest side
  /// <= 256px) by `processCustomIconImage`. When set, it overrides the
  /// fetched favicon everywhere the site's icon renders and in pinned
  /// home shortcuts; null means the automatic favicon. Stored inline in
  /// the model JSON (base64) so it rides settings backups and, for
  /// archive-tier sites, lives only inside the encrypted archive slice —
  /// no per-siteId plaintext file appears on disk (ARCH-006).
  Uint8List? customIconPng;

  /// User-defined domain-claim list used by `LinkRoutingService` to route
  /// inbound share/open-intent URLs to a site (LIR-001..LIR-010). When
  /// null, the resolver behaves as if the site claimed
  /// `[baseDomain(getBaseDomain(initUrl))]` (the legacy synthesized
  /// default). Serialised only when non-null so on-disk JSON for users who
  /// never touch the feature stays byte-identical.
  List<DomainClaim>? domainClaims;

  /// Outbound routing (LIR-013): a cross-domain link this site opens goes to
  /// the site that claims it, with that site's container and settings,
  /// instead of a nested screen with this site's own. Off by default.
  bool routeOutboundLinks;

  /// This site's own routing rules, consulted before the global claims
  /// (LIR-014).
  List<OutboundPreference> get outboundPreferences => _outboundPreferences;
  set outboundPreferences(List<OutboundPreference> value) {
    assert(_onePerClaim(value), 'at most one outbound preference per claim');
    _outboundPreferences = value;
  }

  List<OutboundPreference> _outboundPreferences;

  /// How to search this site (LIR-028): an address with `%s` for the query.
  /// Null means the address its host is known for, if any.
  String? searchAddress;

  /// Whether [searchAddress] searches the whole web rather than this site.
  bool searchesWeb;

  /// The search address this site's own pages declared (LIR-035), used only
  /// while it has no [searchAddress] and its host is not a known one.
  String? discoveredSearchAddress;

  /// Whether [discoveredSearchAddress] searches the whole web: the pages were
  /// a SearXNG instance's.
  bool discoveredSearchesWeb;

  /// How this site searches, if it does (LIR-028).
  SearchCapability? get searchCapability => WebSearchEngine.capabilityOf(
        initUrl: initUrl,
        searchAddress: searchAddress,
        searchesWeb: searchesWeb,
        discoveredAddress: discoveredSearchAddress,
        discoveredWeb: discoveredSearchesWeb,
        listedAddress: SiteSearchListService.instance.addressFor(initUrl),
      );

  /// Take [found] as what this site's pages declared. True when it changed
  /// anything, for the caller to persist.
  bool offerDiscoveredSearch(DiscoveredSearch found) {
    if (discoveredSearchAddress == found.address &&
        discoveredSearchesWeb == found.web) {
      return false;
    }
    discoveredSearchAddress = found.address;
    discoveredSearchesWeb = found.web;
    return true;
  }

  /// The search sites a search from this site offers; empty offers them all.
  List<String> searchSites;

  /// The search site a search from this site starts with; null falls back to
  /// the app default.
  String? searchDefault;

  /// Drop the [searchSites] and [searchDefault] entries that name no
  /// candidate (LIR-031). True when anything was dropped.
  bool pruneSearchReferences(bool Function(String siteId) isCandidate) {
    final kept = [
      for (final id in searchSites)
        if (isCandidate(id)) id,
    ];
    final def = searchDefault;
    final dropDefault = def != null && !isCandidate(def);
    if (kept.length == searchSites.length && !dropDefault) return false;
    searchSites = kept;
    if (dropDefault) searchDefault = null;
    return true;
  }

  /// View used by the resolver: the explicit `domainClaims` if the user has
  /// set them, otherwise the synthesized `[baseDomain(getBaseDomain(initUrl))]`
  /// per LIR-001, which is empty for an [initUrl] with no host.
  List<DomainClaim> get effectiveDomainClaims {
    final explicit = domainClaims;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final uri = Uri.tryParse(initUrl);
    if (uri != null && uri.host.isNotEmpty && uri.hasPort) {
      final h = uri.host.toLowerCase();
      final wrapped = h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
      return [DomainClaim.exactHost('$wrapped:${uri.port}')];
    }
    final base = getBaseDomain(initUrl);
    if (base.isEmpty) return const [];
    return [DomainClaim.baseDomain(base)];
  }

  /// True when [url] is covered by one of this site's domain claims. Every
  /// external-link mode keeps claimed cross-domain links in a nested webview;
  /// only unclaimed ones go to the browser or are blocked.
  bool matchesSiteClaim(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        LinkRoutingService.urlMatchesAnyClaim(uri, effectiveDomainClaims);
  }

  /// Where a link the user explicitly chose to open goes, decided exactly as
  /// a tap on it in this site's on-screen webview would be. For callers that
  /// open a link without the webview's own navigation hook running, such as
  /// the long-press menu: a programmatic `loadUrl` skips
  /// `shouldOverrideUrlLoading` on Android, so a cross-domain URL would
  /// otherwise load inside the site's container. [isActive] is whether the
  /// site is still the one on screen. [homeUrl] and [matchesClaim] anchor a
  /// tab that does not navigate in this site's own domain (LIR-034): the
  /// slot's `navigationHomeUrl` and `navigationMatchesClaim`.
  NavigationDecision decideUserOpenedLink(
    String url, {
    required bool isActive,
    String? homeUrl,
    bool Function(String url)? matchesClaim,
  }) =>
      NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: url,
        initUrl: homeUrl ?? initUrl,
        hasGesture: true,
        isSiteActive: isActive,
        lastSameDomainGestureTime: null,
        now: DateTime.now(),
        externalLinkMode: effectiveExternalLinkMode,
        matchesSiteClaim: matchesClaim ?? matchesSiteClaim,
      ).decision;

  /// Whether the webview is currently mid-navigation. Set true on
  /// `onLoadStart`, false on `onLoadStop`. Driven by the
  /// `WebViewConfig.onLoadingChanged` callback wired in [getWebView].
  /// Consumed by the URL-bar action button to swap Refresh ↔ Stop
  /// while a load is in flight.
  bool isLoading = false;

  /// Re-entrancy guard for [userDrivenReload]. The handler awaits a platform
  /// cache clear before it reloads, so a second tap lands inside the first
  /// call and issues a competing reload against the same webview. Cleared in
  /// a `finally`, so a deliberate second refresh after the first has been
  /// issued still works.
  bool _userReloadInFlight = false;

  /// Recovery state for a main-frame load the OS stranded while the app was
  /// backgrounded (PAUSE-022). Fed by the `WebViewConfig.onMainFrameLoad`
  /// signals wired in [getWebView]; consulted by the host on resume.
  final ResumeReloadEngine resumeReload = ResumeReloadEngine();

  /// Main-frame load progress in 0-100. Driven by the
  /// `WebViewConfig.onProgressChanged` callback wired in [getWebView];
  /// reset to 0 when a navigation starts. Consumed by the app-bar
  /// loading bar, which only renders it while [isLoading] is true.
  int loadingProgress = 0;

  /// Runtime-only marker set when this model was materialised from an
  /// open [Archive] handle rather than restored from app-tier
  /// SharedPreferences. Never serialised. Per the archive feature audit
  /// (ARCH-006), services that touch disk, background scheduling, or
  /// OS-level UI must consult this flag and skip writes for archive-tier
  /// sites. Mutable so a "move to archive" / "move out of archive"
  /// action can flip the tier of an existing model in place — the
  /// running webview keeps its controller and only the per-site routing
  /// changes.
  bool isArchiveTier;

  /// Effective notification permission for runtime gating. Archive-tier
  /// sites never participate in [`NotificationService`] background
  /// polling or `flutter_local_notifications` delivery regardless of
  /// stored value.
  bool get effectiveNotificationsEnabled =>
      ArchiveFold.notifications(notificationsEnabled, archived: isArchiveTier);

  /// Effective background-audio enable. Archive-tier sites never opt out
  /// of lifecycle pausing: audibly playing while the app looks idle (and
  /// surfacing in the OS now-playing UI) would reveal an open archive
  /// (ARCH-006).
  bool get effectiveBackgroundAudioEnabled => ArchiveFold.backgroundAudio(
      backgroundAudioEnabled, archived: isArchiveTier);

  /// Forced on by Tracking Protection (ETP-002), but the archive fold comes
  /// last: an archive-tier site never uses LocalCDN (ARCH-006).
  bool get effectiveLocalCdnEnabled => ArchiveFold.localCdn(
      _forcedByTrackingProtection(
          TrackingProtectionForce.localCdn, localCdnEnabled),
      archived: isArchiveTier);

  /// Effective HTML-cache enable. Archive-tier sites never write the
  /// encrypted-at-rest HTML cache (the cache file path is keyed by
  /// `siteId`, so its existence would correlate to specific archive
  /// sites on disk inspection — ARCH-006).
  bool get effectiveHtmlCachingEnabled =>
      ArchiveFold.htmlCaching(htmlCachingEnabled, archived: isArchiveTier);

  /// Whether this site's block events roll into the app-wide protection
  /// report. Archive-tier sites never do: the report's counters live in
  /// plaintext SharedPreferences, and a counter that only moves while an
  /// archive is open leaks that the archive was used (ARCH-001/ARCH-006).
  /// Per-site live counters (`DnsBlockService`) are unaffected — they are
  /// in-memory and die with the session.
  bool get contributesBlockStats => !isArchiveTier;

  /// Whether this site may persist/restore webview navigation state
  /// (`controller.saveState()` bytes) to the device-key on-disk store.
  /// Single source of truth for the capture, debounce, and cold-start
  /// restore gates. False for:
  /// - **archive-tier** (ARCH-006): the bytes would land in a per-`siteId`
  ///   file whose existence correlates to a specific archive site on disk;
  ///   archive state lives only in the slot-pool ciphertext, never a file.
  /// - **incognito**: navigation state is meant to be ephemeral.
  bool get persistsNavState => !isArchiveTier && !incognito;

  /// Effective incognito decision for the webview container. Archive-tier
  /// sites are always incognito (ARCH-006): otherwise the container writes
  /// localStorage / IndexedDB / ServiceWorker registrations / HTTP cache to
  /// its on-disk directory in cleartext WebKit storage for as long as the
  /// archive is open. A clean archive close tears the container down, but an
  /// unclean process exit (OS kill, force-stop, reboot) would leave that
  /// browsing state on disk, contradicting the spec's "nothing survives a
  /// session beyond cookies." The stored value is preserved for when the
  /// site is moved back out of the archive.
  bool get effectiveIncognito =>
      ArchiveFold.incognito(incognito, archived: isArchiveTier);

  /// What the site may do with sign-ins typed into the HTTP authentication
  /// prompt (HTTPAUTH-004). Archive-tier sites neither read nor save: the
  /// store is app-tier secure storage keyed by `siteId` (ARCH-006).
  /// Incognito sites use a saved sign-in but never save a new one.
  HttpAuthMemory get effectiveHttpAuthMemory => isArchiveTier
      ? HttpAuthMemory.off
      : (incognito ? HttpAuthMemory.readOnly : HttpAuthMemory.readWrite);

  /// Effective third-party cookie enable. Tracking Protection forces it off
  /// (ETP-024): third-party cookies are the oldest cross-site tracking
  /// channel, and leaving them on while the umbrella claims to block
  /// trackers would be the umbrella's largest hole. Grouped with the four
  /// list-based subordinates it already forces on, except that this one is
  /// forced *off* rather than on.
  bool get effectiveThirdPartyCookiesEnabled =>
      _forcedByTrackingProtection(
          TrackingProtectionForce.thirdPartyCookies, thirdPartyCookiesEnabled);

  /// Effective HTTPS upgrade decision. Tracking Protection forces it on
  /// (ETP-030); otherwise the site's own override, or the app-wide default
  /// when it has none. Unlike ETP-002's subordinates this is NOT off when the
  /// umbrella is off: turning the umbrella off to make a site work must not be
  /// what moves a login page to cleartext.
  bool get effectiveHttpsUpgradeEnabled => _forcedByTrackingProtection(
      TrackingProtectionForce.httpsUpgrade,
      Scoped.fromStored(httpsUpgradeEnabled)
          .resolve(AppPref.httpsUpgradeEnabled.value));

  bool _forcedByTrackingProtection(TrackingProtectionForce force, bool stored) =>
      force.resolve(stored, trackingProtection: trackingProtectionEnabled);

  /// Tracking Protection on a proxied site never runs direct WebRTC
  /// (ETP-031). "Proxied" follows the same ladder as the webview's own
  /// traffic, so a DEFAULT site under the app-wide proxy counts; changing
  /// that proxy rebuilds every loaded webview, which re-reads this.
  WebRtcPolicy get effectiveWebRtcPolicy => resolveWebRtcPolicy(
        stored: webRtcPolicy,
        trackingProtectionEnabled: trackingProtectionEnabled,
        proxied: resolveEffectiveProxy(proxySettings, siteId: siteId).type !=
            ProxyType.DEFAULT,
      );

  /// Effective protected-content (Widevine/EME) decision. Archive-tier
  /// sites never grant DRM regardless of stored value: a grant provisions
  /// a per-container Widevine device identifier on disk and the prompt is
  /// OS-level UI, both of which ARCH-006 forbids for archive sites.
  /// Tracking Protection also forces deny (ETP-023): the provisioned
  /// Widevine identifier is a durable device ID that survives the shim's
  /// fingerprint randomization and data clears. Both deny without
  /// prompting (false, never null = never "ask"); the stored value is
  /// preserved for when the umbrella is turned off.
  bool? get effectiveProtectedContentAllowed => resolveProtectedContent(
      protectedContentAllowed,
      archived: isArchiveTier,
      trackingProtection: trackingProtectionEnabled);

  /// What the site captures with. Archive-tier sites are blocked for every
  /// kind (ARCH-006), the stored decisions and files kept for when the site
  /// leaves the archive. Tracking Protection forces nothing here: capture
  /// only starts after an explicit per-site Allow or a user-picked file, so it
  /// is not a silent tracking vector the umbrella needs to close.
  CaptureGrants get effectiveCaptures =>
      ArchiveFold.captures(captures, archived: isArchiveTier);

  @override
  SiteMedia get effectiveMedia => (
    capture: effectiveCaptures,
    protectedContent: effectiveProtectedContentAllowed,
  );

  /// Passkeys (PASSKEY-001): every site but an archive-tier one. The system
  /// passkey sheet is OS-level UI naming the relying party, and a created
  /// passkey lives in the provider's store, outside the archive's keyspace
  /// (ARCH-006).
  bool get effectivePasskeysEnabled => !isArchiveTier;

  /// Archive-tier sites never hand a URL to another app: launching the
  /// system browser is OS-level UI that crosses the archive's isolation
  /// boundary (ARCH-006), so a stored [ExternalLinkMode.browser] keeps links
  /// in-app there. Blocking crosses nothing and stays in force.
  ExternalLinkMode get effectiveExternalLinkMode =>
      ArchiveFold.externalLinks(externalLinkMode, archived: isArchiveTier);

  /// Outbound routing is an option of the in-app mode (LIR-014): in any
  /// other mode the switch is hidden and its stored value inert.
  bool get effectiveRouteOutboundLinks => resolveRouteOutboundLinks(
      route: routeOutboundLinks, mode: externalLinkMode);

  /// Everything a webview that runs as this site applies (CLAUDE.md, "Per-site
  /// settings MUST apply to nested webviews"). The archive tier's overrides
  /// come from the `effective*` getters above; Tracking Protection's forced
  /// subordinates are applied here, by the rules in site_overrides.dart
  /// (ETP-002). Read at the moment a surface is built, so a link opened later
  /// carries the decisions made since. [globalUserScripts] is the app's list,
  /// of which the site opts into some.
  SitePosture sitePosture({required List<UserScriptConfig> globalUserScripts}) {
    final tp = trackingProtectionEnabled;
    bool forced(TrackingProtectionForce force, bool stored) =>
        _forcedByTrackingProtection(force, stored);
    return SitePosture(
      siteId: siteId,
      container: (
        archiveContainerId: archiveContainerId,
        incognito: effectiveIncognito,
        proxy: outboundProxySettings,
        thirdPartyCookies: effectiveThirdPartyCookiesEnabled,
        httpAuthMemory: effectiveHttpAuthMemory,
        passkeys: effectivePasskeysEnabled,
      ),
      blocking: (
        clearUrls: forced(TrackingProtectionForce.clearUrls, clearUrlEnabled),
        dns: forced(TrackingProtectionForce.dnsBlock, dnsBlockEnabled),
        dnsLevel: effectiveDnsBlockLevel,
        contentBlock:
            forced(TrackingProtectionForce.contentBlock, contentBlockEnabled),
        localCdn: effectiveLocalCdnEnabled,
        httpsUpgrade: effectiveHttpsUpgradeEnabled,
        contributesStats: contributesBlockStats,
        blockedCookies: blockedCookies,
      ),
      fingerprint: (
        trackingProtection: tp,
        letterbox: letterboxEnabled,
        windowWidth: spoofWindowWidth,
        windowHeight: spoofWindowHeight,
        resetNonce: fingerprintResetNonce,
      ),
      location: (
        mode: locationMode,
        latitude: spoofLatitude,
        longitude: spoofLongitude,
        accuracy: spoofAccuracy,
        timezone: spoofTimezone,
        granularity: liveLocationGranularity,
        webRtc: effectiveWebRtcPolicy,
      ),
      media: effectiveMedia,
      page: (
        javascript: javascriptEnabled,
        userAgent: effectiveUserAgentOrNull,
        language: language,
        zoomPercent: zoomPercent,
        userScripts: combineUserScripts(globalUserScripts),
        externalLinks: effectiveExternalLinkMode,
        notifications: effectiveNotificationsEnabled,
      ),
    );
  }

  final List<ConsoleLogEntry> consoleLogs = [];
  static const _maxConsoleLogs = 500;
  VoidCallback? onConsoleLogChanged;

  String? defaultUserAgent;
  Function? stateSetterF;
  /// Host hook fired once each time a fresh native controller attaches for
  /// this model (cold start, `_goHome` recreate, renderer-gone recovery,
  /// savedForRestore re-creation). The host uses it to recomposite the
  /// Android hybrid-composition surface, which can re-attach blank-white
  /// when a new platform view mounts. Re-activation of an already-loaded
  /// webview does NOT recreate the controller, so it does not fire here —
  /// that path is nudged explicitly by `_setCurrentIndex`.
  Function? onControllerReady;
  /// Host hook fired when a reload is issued for this model's webview
  /// ([reloadAndRepaint], the funnel every reload goes through). A reload
  /// discards the document's painted frame and recommits it later, so on
  /// Android the hybrid-composition surface can sit blank in between
  /// (BUG-001 / PAUSE-021). The host latches the reload here and nudges;
  /// [onLoadSettled] closes the pair when the new document commits.
  VoidCallback? onReloadIssued;
  /// Host hook fired when a main-frame load settles (`onLoadingChanged`
  /// false). Only meaningful paired with [onReloadIssued]: it is the
  /// closest Dart-side signal to the reloaded document committing onto
  /// the surface, which is the moment the repaint has to land (PAUSE-021).
  VoidCallback? onLoadSettled;
  /// Host hook fired when the WebView commits its first visible frame for a
  /// navigation (Android `onPageCommitVisible`). Unlike [onLoadSettled] this
  /// reports that pixels exist rather than that a load finished, so it is the
  /// one repaint trigger that cannot fire before there is something to paint
  /// (BUG-001 gap #18).
  VoidCallback? onPageCommitVisible;
  /// Host hook fired once per committed navigation (deduped across the
  /// `onLoadStop` / `onUpdateVisitedHistory` double-fire). The host
  /// debounces `controller.saveState()` captures off this so the
  /// persisted back/forward stack tracks browsing instead of only
  /// pause/dispose events (PAUSE-009) — the app-switcher swipe-kill
  /// never delivers `paused`, and background notification sites
  /// navigate while another site is current.
  VoidCallback? onNavigationCommitted;
  FindMatchesResult findMatches = FindMatchesResult();
  WebViewTheme _currentTheme = WebViewTheme.light;

  /// The theme most recently applied to this webview via [setTheme]. Used
  /// by callers (e.g. HTML cache prelude) that need to render a frame that
  /// matches the current theme before scripts and stylesheets load.
  WebViewTheme get currentTheme => _currentTheme;

  /// The UA string webviews are actually built with: presets render fresh
  /// at the current Firefox version; custom strings pass through verbatim.
  String get effectiveUserAgent => uaPreset == null
      ? userAgent
      : renderUserAgentPreset(
          uaPreset!, FirefoxUserAgentService.instance.versionString);

  /// [effectiveUserAgent] in the null-for-unset form the webview expects.
  String? get effectiveUserAgentOrNull {
    final ua = effectiveUserAgent;
    return ua.isEmpty ? null : ua;
  }

  /// Store a user-entered UA. Strings that exactly match a generated
  /// shape (any version, including shapes only older builds emitted) get
  /// their preset back, so they keep re-rendering fresh; anything else is
  /// custom and preserved verbatim.
  ///
  /// An empty string, the platform's current default UA, or a stock
  /// webview-default shape all clear the override entirely: the webview
  /// then sends its own live default, which stays current with OS/WebView
  /// updates instead of freezing at capture time.
  void setUserAgent(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed == defaultUserAgent ||
        isStockWebViewDefaultUserAgent(trimmed)) {
      userAgent = '';
      uaPreset = null;
      return;
    }
    userAgent = trimmed;
    uaPreset = recognizeGeneratedUserAgent(trimmed);
  }

  WebViewModel({
    String? siteId,
    required this.initUrl,
    String? currentUrl,
    List<SiteTab>? tabs,
    String? activeTabId,
    String? name,
    this.cookies = const [],
    UserProxySettings? proxySettings,
    this.javascriptEnabled = true,
    this.userAgent = '',
    this.uaPreset,
    this.thirdPartyCookiesEnabled = false,
    this.httpsUpgradeEnabled,
    this.incognito = false,
    this.alwaysOpenHome = false,
    this.kioskMode = false,
    this.tabsEnabled = true,
    this.containerColor,
    this.language,
    this.zoomPercent = kDefaultZoomPercent,
    this.clearUrlEnabled = true,
    this.dnsBlockEnabled = true,
    this.dnsBlockLevel,
    this.contentBlockEnabled = true,
    this.disabledFilterLists = const <String>{},
    this.trackingProtectionEnabled = true,
    this.localCdnEnabled = true,
    this.externalLinkMode = ExternalLinkMode.inApp,
    this.fullscreenMode = false,
    this.blockScreenshots = false,
    this.tabBarButtonCorner,
    this.htmlCachingEnabled = false,
    this.notificationsEnabled = false,
    this.backgroundAudioEnabled = false,
    this.protectedContentAllowed,
    this.captures = CaptureGrants.none,
    List<UserScriptConfig>? userScripts,
    Set<String>? enabledGlobalScriptIds,
    Set<BlockedCookie>? blockedCookies,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = kDefaultSpoofAccuracy,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.liveLocationGranularity = LocationGranularity.gps,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.letterboxEnabled = false,
    this.spoofWindowWidth,
    this.spoofWindowHeight,
    this.fingerprintResetNonce,
    this.customIconPng,
    this.domainClaims,
    this.routeOutboundLinks = false,
    List<OutboundPreference>? outboundPreferences,
    this.searchAddress,
    this.searchesWeb = false,
    this.discoveredSearchAddress,
    this.discoveredSearchesWeb = false,
    List<String>? searchSites,
    this.searchDefault,
    this.stateSetterF,
    this.isArchiveTier = false,
  })  : assert(_onePerClaim(outboundPreferences ?? const []),
            'at most one outbound preference per claim'),
        userScripts = userScripts ?? [],
        _outboundPreferences = outboundPreferences ?? [],
        searchSites = searchSites ?? [],
        enabledGlobalScriptIds = enabledGlobalScriptIds ?? {},
        blockedCookies = blockedCookies ?? {},
        siteId = siteId ?? _generateSiteId(),
        name = name ?? extractDomain(initUrl),
        proxySettings = proxySettings ?? UserProxySettings(type: ProxyType.DEFAULT) {
    // A site always has at least one tab, so `currentUrl` always has somewhere
    // to live. The engine also repairs a list that arrived from an imported
    // backup: duplicate ids, a parent that names a tab that is not here, a
    // parent cycle.
    // `currentUrl` here is the constructor parameter, not the getter above it:
    // the getter reads `tabs`, which this call is what fills in.
    final seeded = TabLifecycleEngine.normalize(
      tabs,
      activeTabId,
      currentUrl ?? initUrl,
    );
    this.tabs = seeded.tabs;
    this.activeTabId = seeded.activeTabId;
    for (final t in this.tabs) {
      if (t.hostSiteId == this.siteId) t.hostSiteId = null;
    }
  }

  /// This site's proxy as outbound seams should see it.
  ///
  /// Identical to [proxySettings] for every type but [ProxyType.TOR], where
  /// it returns a copy carrying [siteId] as the SOCKS5 stream-isolation tag.
  /// A *copy*, deliberately: stamping the tag into the stored object would
  /// overwrite the user's manual proxy username, and PROXY-010 requires the
  /// manual credentials survive a trip through TOR so switching back
  /// restores them.
  ///
  /// Pass this — not [proxySettings] — to anything that opens a connection
  /// on the site's behalf (favicons, downloads, user scripts, the webview),
  /// or that traffic lands on the app-global circuit instead of the site's
  /// and becomes correlatable with it.
  UserProxySettings get outboundProxySettings {
    if (proxySettings.type != ProxyType.TOR) return proxySettings;
    return UserProxySettings(
      type: ProxyType.TOR,
      address: proxySettings.address,
      username: siteId,
      torExitCountry: proxySettings.torExitCountry,
    );
  }

  /// Reroll the per-site anti-fingerprinting seed. Called when the user
  /// clears this site's data so the post-wipe page sees a fresh fingerprint
  /// (window size, canvas, WebGL, …) and can't re-identify the user (ETP-022).
  void rerollFingerprint() {
    fingerprintResetNonce = generateFingerprintResetNonce();
  }

  /// Check if a cookie is blocked by name + domain for this site.
  bool isCookieBlocked(String name, String? domain) =>
      matchesBlockedCookie(blockedCookies, name, domain);

  /// Completes with whether the proxy override was applied for the current
  /// controller. The restore path awaits it before materialising, so no
  /// navigation leaves before the Android/Linux override is in place.
  Completer<bool>? _proxyReady;
  Future<bool> get proxyReady => _proxyReady?.future ?? Future.value(true);

  /// Set by [getWebView] when the platform view was built without an
  /// initial load because the proxy override had to land first
  /// (`deferInitialLoadForProxy`). One-shot: [setController] issues the load.
  bool _initialLoadDeferredForProxy = false;

  /// Set by [getWebView] to the container whose proxy the site no longer
  /// names (PROXY-029). One-shot: [_applyProxySettings] clears it.
  String? _containerProxyToRelease;

  Future<void> setController() async {
    if (controller == null) {
      return;
    }
    // Read before the first await: onControllerCreated consumes the pending
    // restore right after calling us, and that path issues its own load.
    final restorePending = _pendingRestoreState != null;
    final ready = Completer<bool>();
    _proxyReady = ready;
    // Apply proxy settings first (before loading any URLs)
    final proxyApplied = await _applyProxySettings();
    ready.complete(proxyApplied);
    if (_initialLoadDeferredForProxy) {
      _initialLoadDeferredForProxy = false;
      if (proxyApplied && !restorePending) {
        await controller?.loadUrl(currentUrl);
      }
    }

    final c = controller;
    if (c == null) return;
    final id = runningIdentity;
    await c.setOptions(
      javascriptEnabled: id.javascriptEnabled,
      userAgent: id.effectiveUserAgentOrNull,
      thirdPartyCookiesEnabled: id.effectiveThirdPartyCookiesEnabled,
      incognito: id.effectiveIncognito,
    );
    await c.setThemePreference(_currentTheme);
    defaultUserAgent ??= await c.getDefaultUserAgent();
  }

  /// Apply proxy settings to the webview.
  ///
  /// Android: routes through the global `inapp.ProxyController`. Takes
  /// effect on next request without reload.
  ///
  /// iOS / macOS: the per-site proxy is bound to the per-site
  /// `WKWebsiteDataStore` at WebView construction (via
  /// `inapp.InAppWebViewSettings.proxySettings`). To pick up a runtime
  /// change, the WebView must be rebuilt; see [updateProxySettings]. The one
  /// thing construction cannot do is take a proxy off a container, so a
  /// site that stopped naming one clears it here (PROXY-029).
  Future<bool> _applyProxySettings() async {
    final proxyManager = ProxyManager();
    // LIR-024: the process-global proxy follows the site the slot runs as.
    final id = runningIdentity;
    try {
      await proxyManager.setProxySettings(id.proxySettings, siteId: id.siteId);
      final release = _containerProxyToRelease;
      _containerProxyToRelease = null;
      if (release != null) await proxyManager.releaseContainerProxy(release);
      return true;
    } catch (e) {
      // Exception text can include proxy host / username / scheme, which
      // are per-site identifiers for any site with a custom proxy (including
      // archive-tier sites). Keep in the memory ring.
      LogTag.webView
          .error('Failed to apply proxy settings: $e', sensitive: true);
      // Fail closed: ProxyManager.setProxySettings throws precisely to
      // refuse a direct fallback (relay bind failure, malformed host:port).
      // If the site expected a real proxy, swallowing the throw would let
      // the already-initialized page load over the device IP. Blank the
      // load instead of leaking. `setProxySettings` throws on the effective
      // proxy, so a DEFAULT site inheriting an unusable global proxy blanks
      // too (LEAK-003).
      if (resolveEffectiveProxy(id.proxySettings, siteId: id.siteId).type !=
          ProxyType.DEFAULT) {
        await controller?.stopLoading();
        await controller?.loadUrl('about:blank');
      }
      return false;
    }
  }

  /// Combine this site's per-site scripts with opted-in globals into the
  /// list to inject. Forces `enabled: true` on globals so a stale stored
  /// flag (e.g. a disabled site script later promoted via "Make Global")
  /// can't silently drop the script in
  /// `UserScriptService.buildInitialUserScripts`.
  List<UserScriptConfig> combineUserScripts(
      List<UserScriptConfig> globalUserScripts) {
    return [
      ...globalUserScripts
          .where((g) => enabledGlobalScriptIds.contains(g.id))
          .map((g) => UserScriptConfig(
                id: g.id,
                name: g.name,
                source: g.source,
                url: g.url,
                urlSource: g.urlSource,
                injectionTime: g.injectionTime,
                enabled: true,
              )),
      ...userScripts,
    ];
  }

  /// Apply theme preference to the webview
  Future<void> setTheme(WebViewTheme theme) async {
    _currentTheme = theme;
    if (webview != null) await controller?.setThemePreference(theme);
  }

  /// Update proxy settings and apply them.
  ///
  /// On iOS / macOS, the proxy is sealed into the per-site
  /// `WKWebsiteDataStore` at WebView construction time. To pick up the
  /// new value, the live WebView is discarded so the next render
  /// reconstructs it with the new `inapp.InAppWebViewSettings.proxySettings`
  /// dictionary. The caller MUST trigger a rebuild (typically via
  /// `setState`) so the IndexedStack actually re-creates the slot.
  Future<void> updateProxySettings(UserProxySettings newSettings) async {
    proxySettings = newSettings;
    if (hostIsIOS || hostIsMacOS) {
      disposeWebView();
      return;
    }
    await _applyProxySettings();
  }

  /// The site as itself, at its home page, for a headless check in a
  /// background wake (NOTIF-016). Built from the same [sitePosture] as
  /// [getWebView]'s config, so every per-site field reaches the check, under
  /// [hooks] that answer no one: nothing is on screen.
  WebViewConfig headlessCheckConfig(WebViewHostHooks hooks) => WebViewConfig(
        posture: sitePosture(globalUserScripts: hooks.globalUserScripts()),
        hooks: hooks.unattended(),
        initialUrl: initUrl,
      );

  /// The slot's webview, built on first call; null while the site waits for
  /// Tor (TOR-008). [initialHtml] renders before the live load;
  /// [onHtmlLoaded], gated by [shouldFetchHtml], keeps the offline snapshot.
  /// All three are the slot's HTML cache, and absent when it has none.
  Widget? getWebView(
    WebViewHostHooks hooks, {
    String? initialHtml,
    void Function(String url, String html)? onHtmlLoaded,
    bool Function()? shouldFetchHtml,
  }) {
    // LIR-018: a hosted tab runs as its host. Everything that decides the
    // container, the posture and the navigation rules reads [id]; the slot's
    // own state (webview, controller, loading, the tab record) stays here.
    if (activeHostMissing) return const SizedBox.shrink();
    final WebViewModel id = runningIdentity;
    final bool hosted = !identical(id, this);
    final String ownerDomain = getNormalizedDomain(initUrl);
    // LIR-034: a foreign tab runs as [id] but navigates in its link's domain.
    final String navHome = navigationHomeUrl;
    final bool Function(String) navClaim =
        runsForeignTab ? (_) => false : id.matchesSiteClaim;
    // S6: in a hosted or foreign tab, a link back into this site's own domain
    // returns to this site as a child tab instead of leaving by the rules of
    // the tab it came from.
    bool returnsToOwner(String url) =>
        (hosted || runsForeignTab) &&
        onReturnToOwner != null &&
        getNormalizedDomain(url) == ownerDomain;
    bool isActive() => hooks.onScreen(this);
    final globalUserScripts = hooks.globalUserScripts();
    // Carries out a navigation decision, for a tap and a redirect alike:
    // false when this webview must not load [url]. The host's outbound hook
    // may take a leaving link over first (LIR-014) and hears of a blocked one
    // (NESTED-009).
    bool dispatch(NavigationDecision decision, String url, bool hadGesture,
        {required String via}) {
      LogTag.webView.debug('$via -> ${decision.name} $url', sensitive: true);
      if (NavigationDecisionEngine.stepFor(decision,
              returnsToOwner: returnsToOwner(url)) ==
          NavigationStep.returnToOwner) {
        onReturnToOwner?.call(url);
        return false;
      }
      bool takenOver() => hooks.routeOutbound(this, url, decision, hadGesture);
      switch (decision) {
        case NavigationDecision.allow:
          return true;
        case NavigationDecision.blockSilent:
        case NavigationDecision.blockSuppressed:
          return false;
        case NavigationDecision.blockOpenNested:
          if (!takenOver()) {
            hooks.launchNested(
              url,
              id.sitePosture(globalUserScripts: globalUserScripts),
              homeTitle: id.name,
            );
          }
          return false;
        case NavigationDecision.blockOpenExternal:
          if (!takenOver()) hooks.openInBrowser(url);
          return false;
        case NavigationDecision.blockOutbound:
          takenOver();
          return false;
      }
    }
    // Fail closed while Tor is still bootstrapping (TOR-008), for explicit
    // Tor sites and for DEFAULT sites inheriting a global Tor (PROXY-011).
    // Constructing an InAppWebView here with a null proxy binds its
    // WKWebsiteDataStore to no proxy for the life of the widget, so a later
    // `Up` transition would silently leak — hence the widget-level gate
    // rather than a proxy substitution.
    final effectiveProxy =
        resolveEffectiveProxy(id.proxySettings, siteId: id.siteId);
    if (waitsForTor(
      id.proxySettings,
      siteId: id.siteId,
      torUp: TorService.instance.status.isUp,
    )) {
      return null;
    }
    if (webview == null) {
      LogTag.webView.debug(
          'Creating webview for "$name" (siteId: $siteId, initUrl: $initUrl'
          '${hosted ? ', running as ${id.siteId}' : ''})', sensitive: true);
      LogTag.webView.debug(
          'Using cached HTML: ${initialHtml != null} (${initialHtml?.length ?? 0} bytes)',
          sensitive: true);
      final pullToRefreshGate =
          PullToRefreshGate.forHost(onRefresh: userDrivenReload);
      // Track last user gesture on same-domain navigation, so we can
      // propagate it to cross-domain redirects (e.g., search engine
      // redirect links like DuckDuckGo's /l/?uddg=... or Google's /url?q=...).
      DateTime? lastSameDomainGestureTime;
      // Immutable state for the onUrlChanged handler, owned here and
      // swapped by `NavigationDecisionEngine.handleOnUrlChanged`. Carries
      // redirectHandled / previousSameDomainUrl / currentUrl; the engine
      // enforces the invariants (see its class-level doc).
      var urlChangedState = OnUrlChangedState.initial(currentUrl);
      // The URL we most recently fired the post-state-commit IPC chain
      // (`getTitle` + `setThemePreference`) for. `onUrlChanged` is wired
      // up to BOTH `onLoadStop` and `onUpdateVisitedHistory` in
      // webview.dart, so a single navigation reliably produces two
      // events with the same URL — without dedup we'd post 2× getTitle
      // + 2× evaluateJavascript IPCs per navigation, doubling the
      // race-window count for the chromium dangling-raw_ptr crash.
      String? lastNotifiedUrl;
      // Android restore ordering: when nav-state bytes are queued for this
      // build, the webview must apply restoreState to a pristine back/forward
      // list. Suppress the initial load on Android and materialize the
      // restored entry from onControllerCreated; iOS/macOS keep the
      // initialUrlRequest load and replace state in place via interactionState.
      final bool deferRestoreLoad = deferInitialLoadForRestore(
        hasPendingRestoreState: _pendingRestoreState != null,
        isAndroid: hostIsAndroid,
        isFileImport: currentUrl.startsWith('file://'),
      );
      final posture = id.sitePosture(globalUserScripts: globalUserScripts);
      final storeBinding = WebViewFactory.storeBinding(posture);
      _containerProxyToRelease = storeBinding.releasesContainerProxy
          ? storeBinding.containerId
          : null;
      final bool deferForProxy = deferInitialLoadForProxy(
        proxyIsGlobal: hostIsAndroid || hostIsLinux,
        effectiveNonDefault: effectiveProxy.type != ProxyType.DEFAULT,
        overrideActive: ProxyManager.overrideActive,
        releasesContainerProxy: storeBinding.releasesContainerProxy,
      );
      _initialLoadDeferredForProxy = deferForProxy && !deferRestoreLoad;
      final iconSiteUrl = id.initUrl;
      webview = WebViewFactory.createWebView(
        config: WebViewConfig(
          key: UniqueKey(), // Force new widget state when recreating
          posture: posture,
          hooks: hooks,
          initialUrl: currentUrl,
          // Root site webview sits at the MaterialApp root route: on iOS/macOS
          // there is no Flutter route-pop edge-swipe here, so opt into
          // WKWebView's native back/forward swipe. Nested screens don't (NAV-008).
          backForwardGestures: true,
          deferInitialLoad: deferRestoreLoad || deferForProxy,
          backgroundAudioEnabled: effectiveBackgroundAudioEnabled,
          onLinkLongPress: (url) => hooks.linkMenu(this, url),
          grants: PersistedGrantStore(
            id,
            prompter: hooks.media,
            isSiteActive: isActive,
            save: hooks.save,
          ),
          pullToRefreshGate: pullToRefreshGate,
          onUnproxiedNavigationBlocked: (blocked) {
            blockedNavigationUrl = blocked;
            hooks.rebuild();
          },
          shouldOverrideUrlLoading: (url, hasGesture) {
            LogTag.webView.debug(
                'shouldOverrideUrlLoading: site="$name" (siteId: $siteId) initUrl=$initUrl request=$url hasGesture=$hasGesture',
                sensitive: true);
            final now = DateTime.now();
            final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
              targetUrl: url,
              initUrl: navHome,
              hasGesture: hasGesture,
              isSiteActive: isActive(),
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: now,
              externalLinkMode: id.effectiveExternalLinkMode,
              matchesSiteClaim: navClaim,
            );
            lastSameDomainGestureTime =
                result.gestureUpdate.applyTo(lastSameDomainGestureTime, now);
            return dispatch(result.decision, url, result.hadGesture,
                via: 'shouldOverrideUrlLoading');
          },
          onReloadIssued: () => onReloadIssued?.call(),
          onMainFrameLoad: resumeReload.noteLoad,
          onLoadingChanged: (loading) {
            if (isLoading == loading) return;
            isLoading = loading;
            // Reset on start so the bar doesn't flash the previous
            // navigation's near-complete value.
            if (loading) loadingProgress = 0;
            // A settled load is the reloaded document committing onto the
            // surface; the host repaints there rather than at reload-issue
            // time, when there is nothing yet to paint (PAUSE-021).
            if (!loading) onLoadSettled?.call();
            // Trigger a UI rebuild so the URL-bar action button can
            // swap between Refresh and Stop. saveFunc is intentionally
            // NOT called here — the loading bool is transient runtime
            // state, not part of the persisted site model.
            stateSetterF?.call();
          },
          onProgressChanged: (progress) {
            if (loadingProgress == progress) return;
            loadingProgress = progress;
            // Transient runtime state, same contract as onLoadingChanged.
            stateSetterF?.call();
          },
          onUrlChanged: (url) async {
            // A server-side redirect (DuckDuckGo's /l/?uddg=, Google's
            // /url?q=) arrives here without passing shouldOverrideUrlLoading.
            final now = DateTime.now();
            final handled = NavigationDecisionEngine.handleOnUrlChanged(
              newUrl: url,
              initUrl: navHome,
              isSiteActive: isActive(),
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: now,
              isCaptchaChallenge: (u) =>
                  WebViewFactory.isCaptchaChallenge(u, siteUrl: navHome),
              state: urlChangedState,
              externalLinkMode: id.effectiveExternalLinkMode,
              matchesSiteClaim: navClaim,
            );
            lastSameDomainGestureTime =
                handled.gestureUpdate.applyTo(lastSameDomainGestureTime, now);
            urlChangedState = handled.state;
            // No navigate-back to the last same-domain page: even
            // stopLoading + microtask + loadUrl(prev) races Chromium's
            // in-flight cross-origin redirect on the Android WebView build
            // that SIGTRAPs at `partition_alloc_support.cc:770` (LinkedIn's
            // safety/go -> reddit). The parent shows the redirect target
            // until the next navigation; the nested webview still opens.
            final decision = handled.decision;
            if (decision != null &&
                !dispatch(decision, url, handled.hadGesture,
                    via: 'onUrlChanged')) {
              return;
            }
            currentUrl = urlChangedState.currentUrl;
            stateSetterF?.call();
            // Get page title and update name if we have a title.
            // Skip the title + theme IPCs when the URL didn't actually
            // advance — this is the duplicate event from the other of
            // `onLoadStop` / `onUpdateVisitedHistory` firing for the
            // same URL we just processed. Halves the chromium IPC
            // traffic per real navigation, removing one race window
            // for the `partition_alloc_support.cc:770` dangling-raw_ptr
            // SIGTRAP that can fire when an `evaluateJavascript`
            // continuation lands on a frame chromium has torn down.
            final currentNotifyUrl = urlChangedState.currentUrl;
            if (currentNotifyUrl != lastNotifiedUrl) {
              lastNotifiedUrl = currentNotifyUrl;
              onNavigationCommitted?.call();
              // Each await below is a yield point where disposeWebView() can
              // null `controller`, so we re-check before every native call —
              // calling into a torn-down WebView peer can trip Chromium's
              // dangling raw_ptr detector and SIGTRAP the renderer.
              if (controller == null) return;
              final title = await controller!.getTitle();
              if (controller == null) return;
              if (title != null && title.isNotEmpty) {
                pageTitle = title;
                // Auto-update name from page title if name is still the default domain
                if (!hosted && name == extractDomain(initUrl)) {
                  name = title;
                }
              }
              // Reapply theme after page load (some sites might override it).
              // Fire-and-forget: don't await. The await chained an
              // evaluateJavascript continuation onto our local Dart future,
              // and that continuation is the candidate that lands on a
              // dying frame when chromium tears down between our request
              // and its dispatch. The theme call doesn't gate any
              // subsequent work — saveFunc below is Dart-only.
              controller?.setThemePreference(_currentTheme);
            }
            await hooks.save();
          },
          onCookiesChanged: (newCookies) async {
            // Remove blocked cookies from the webview cookie jar. The mirror
            // and the block list are those of the site the slot runs as.
            if (id.blockedCookies.isNotEmpty) {
              final blocked = newCookies.where((c) => id.isCookieBlocked(c.name, c.domain)).toList();
              final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : id.initUrl);
              for (final c in blocked) {
                final containerCookieManager = hooks.containerCookieManager;
                if (containerCookieManager != null) {
                  await containerCookieManager.deleteCookie(
                    controller: controller,
                    siteId: id.siteId,
                    url: url,
                    name: c.name,
                    domain: c.domain,
                    path: c.path ?? '/',
                  );
                } else {
                  await hooks.cookieManager.deleteCookie(
                    url: url,
                    name: c.name,
                    domain: c.domain,
                    path: c.path ?? '/',
                  );
                }
              }
              id.cookies = newCookies.where((c) => !id.isCookieBlocked(c.name, c.domain)).toList();
            } else {
              id.cookies = newCookies;
            }
            await hooks.save();
          },
          onFindResult: (activeMatch, totalMatches) {
            findMatches.activeMatchOrdinal = activeMatch;
            findMatches.numberOfMatches = totalMatches;
            if (stateSetterF != null) {
              stateSetterF!();
            }
          },
          onHtmlLoaded: onHtmlLoaded,
          shouldFetchHtml: shouldFetchHtml,
          initialHtml: initialHtml,
          onRendererGone: (didCrash) => handleRendererGone(didCrash: didCrash),
          onPageCommitVisible: () => onPageCommitVisible?.call(),
          passkeys: PasskeyAccess.forHost(
            enabled: posture.container.passkeys,
            isOnScreen: isActive,
          ),
          siteIcon: SiteIconTarget(
            siteUrl: iconSiteUrl,
            // Incognito and archive-tier icons stay in memory: an icon the
            // site served (an unread badge) is state it must not leave on disk.
            onIcon: (icon) => unawaited(SiteIconStore.instance
                .offer(iconSiteUrl, icon, persist: !id.effectiveIncognito)),
          ),
          siteSearch: WebSearchEngine.discovers(
                  initUrl: id.initUrl, searchAddress: id.searchAddress)
              ? SiteSearchTarget(
                  siteUrl: id.initUrl,
                  // Search ships behind the Site tabs switch (LIR-029).
                  enabled: () => ExperimentalFeaturesService.instance
                      .isEnabled(ExperimentalFeature.siteTabs),
                  onSearch: (found) {
                    if (!id.offerDiscoveredSearch(found)) return;
                    stateSetterF?.call();
                    unawaited(hooks.save());
                  },
                )
              : null,
          onConsoleMessage: (message, level) {
            consoleLogs.add(ConsoleLogEntry(
              timestamp: DateTime.now(),
              message: message,
              level: level,
            ));
            if (consoleLogs.length > _maxConsoleLogs) {
              consoleLogs.removeAt(0);
            }
            onConsoleLogChanged?.call();
          },
        ),
        onControllerCreated: (ctrl) {
          LogTag.webView.debug(
              'onControllerCreated for "$name" (siteId: $siteId)',
              sensitive: true);
          controller = ctrl;
          setController();
          unawaited(_pushPendingArchiveCookies(ctrl));
          // Apply any state queued by the activation flow when this
          // model came back from SavedForRestore. The InAppWebView's
          // `initialUrlRequest` already kicked off a navigation to
          // `currentUrl` (which matches the most-recent saved URL);
          // restoreState restores the back/forward stack on Android
          // and (Apple 15+/12+) form-field values. The brief
          // redundant initial-nav-then-restore on Apple is acceptable
          // for the much-better re-activation UX.
          //
          // unawaited: subsequent webview-creation logic doesn't
          // depend on the restore completing. Clear the field
          // *before* awaiting so a back-to-back rebuild doesn't
          // re-apply the same bytes.
          final pending = _pendingRestoreState;
          if (pending != null) {
            _pendingRestoreState = null;
            // On Android the webview was built with no initial load
            // (deferRestoreLoad), so restoreState applies to a pristine
            // back/forward list. Android does not restore display data, so
            // the current entry must then be materialized with an explicit
            // reload. iOS/macOS already kicked off the initialUrlRequest load
            // and replace state in place via interactionState, so they skip
            // this — the page is already on screen, unless the load waited
            // for a container proxy to be cleared and nothing is.
            final materialize =
                deferRestoreLoad || storeBinding.releasesContainerProxy;
            final restoreUrl = currentUrl;
            unawaited(() async {
              // The override must land before the restored entry loads;
              // on a proxy failure stay blank (fail closed).
              if (!await proxyReady) return;
              final ok = await ctrl.restoreState(pending);
              LogTag.webView.debug(
                  'restoreState for "$name" (siteId: $siteId): $ok',
                  sensitive: true);
              if (materialize) {
                // ok: reload the restored top entry (keeps the back stack).
                // !ok: nothing was restored, so just load the saved URL or
                // the suppressed-initial-load webview would stay blank.
                if (ok) {
                  await reloadAndRepaint(ctrl);
                } else {
                  await ctrl.loadUrl(restoreUrl);
                }
              }
            }());
          }
          // A brand-new platform-view surface just attached; let the host
          // recomposite it if this is the visible site (Android blank-white
          // surface recovery). Fires for every fresh controller, so it
          // covers _goHome, renderer-gone rebuild, and savedForRestore
          // re-creation in one place — paths _setCurrentIndex's own nudge
          // does not reach because they don't go through it.
          onControllerReady?.call();
        },
      );
    }
    return webview;
  }

  WebViewController? getController(WebViewHostHooks hooks) {
    if (webview == null) getWebView(hooks);
    if (controller != null) {
      setController();
    }
    return controller;
  }

  Future<void> deleteCookies(CookieManager cookieManager,
      ContainerCookieManager? containerCookieManager) async {
    final url = Uri.parse(initUrl);
    for (final Cookie cookie in cookies) {
      if (containerCookieManager != null) {
        await containerCookieManager.deleteCookie(
          controller: controller,
          siteId: siteId,
          url: url,
          name: cookie.name,
          domain: cookie.domain,
          path: cookie.path ?? "/",
        );
      } else {
        await cookieManager.deleteCookie(
          url: url,
          name: cookie.name,
          domain: cookie.domain,
          path: cookie.path ?? "/",
        );
      }
    }
    cookies = [];
  }

  /// Capture current cookies from CookieManager and store locally.
  /// Used for per-site cookie isolation when switching between same-domain sites.
  Future<void> captureCookies(CookieManager cookieManager) async {
    if (incognito) return; // Don't capture cookies for incognito sites
    final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : initUrl);
    cookies = await cookieManager.getCookies(url: url);
  }

  /// Drop the cached webview widget and controller, then ask the host to
  /// rebuild. Used when the renderer process is killed (Android `onRender-
  /// ProcessGone`, iOS/macOS `onWebContentProcessDidTerminate`) — the view
  /// is alive but has no renderer driving it, which paints as a black
  /// surface on resume from background (issue #333). Recreation is the only
  /// supported recovery per Android docs; the native WebView cannot recover
  /// in place. The user loses the live JS heap and DOM, which is unavoidable
  /// since the process holding them is gone — `currentUrl` is reloaded so
  /// the back-/forward stack is the only thing dropped.
  void handleRendererGone({required bool didCrash}) {
    LogTag.webView.debug(
        'Renderer gone for "$name" (siteId: $siteId, didCrash: $didCrash) — recreating');
    webview = null;
    controller = null;
    resumeReload.reset();
    stateSetterF?.call();
  }

  /// Per-instance pause for site switches.
  ///
  /// Reduces resource usage but does NOT fully stop the page — Web Workers,
  /// Service Workers, in-flight network requests (and the `Set-Cookie` they
  /// return), media playback, WebRTC and WebSocket I/O all keep running. On
  /// Android, JS timers also keep running (Android's per-instance pause does
  /// not cover them, and the global timer pause would freeze other tabs too).
  /// This is a resource hint, not a security boundary — see
  /// [WebViewController.pause] for the full caveat list. To safely mutate
  /// cookies or proxy under a webview, dispose it instead.
  ///
  /// Skipped for sites with [notificationsEnabled] set: on iOS, per-instance
  /// pause is implemented via `pauseTimers()` (the plugin's alert-deadlock
  /// hack), which freezes this WebView's JS thread. That stalls any
  /// setInterval / setTimeout / WebSocket-driven notification poller until
  /// the user switches back, at which point all queued notifications fire
  /// at once. Sites the user enabled notifications on must keep running.
  ///
  /// Also skipped for sites with [backgroundAudioEnabled] (BGAUDIO-001): the
  /// same iOS alert-hack freeze would stall a streaming player's JS the
  /// moment the user switches to another site, cutting the audio the toggle
  /// exists to keep playing.
  Future<void> pauseWebView() async {
    if (controller == null) return;
    if (notificationsEnabled) return;
    if (effectiveBackgroundAudioEnabled) return;
    await controller!.pause();
    LogTag.webView.debug(
        'Paused webview for "$name" (siteId: $siteId)', sensitive: true);
  }

  /// End any device capture this site is running: camera (CAM-012) and
  /// microphone (MIC-012), through one hook over the shims' shared registry.
  ///
  /// Called when the site stops being the one on screen. The simulated camera
  /// and microphone keep streaming: they are local files the user picked, so
  /// nothing is being observed, and ending them would drop a half-finished
  /// scan or stop playback the user comes back to.
  ///
  /// Two properties this must keep, both easy to lose:
  ///   * it runs BEFORE [pauseWebView] at every call site — the iOS
  ///     per-instance pause blocks the page's JS thread, so JS posted after it
  ///     would not run until the site is resumed;
  ///   * it is NOT folded into [pauseWebView], which early-returns for
  ///     notification and background-audio sites. Those sites may keep running
  ///     JS and audio in the background. The camera is not covered by either.
  Future<void> stopRealCapture() async {
    await controller?.evaluateJavascript(
      "if (typeof globalThis.__wsStopRealCapture === 'function') "
      'globalThis.__wsStopRealCapture();',
    );
  }

  /// Tell a background-audio site's page whether the app is backgrounded
  /// (BGAUDIO-012), so its media-session shim can mask the page-visibility
  /// APIs and re-issue `play()` if the page stopped itself anyway.
  ///
  /// A no-op for every other site: masking visibility for a page the user did
  /// not opt in for would keep timers and players running that should stop.
  /// Main frame only — the shim relays the state to its own subframes.
  Future<void> setBackgroundPlayback(bool active) async {
    if (!effectiveBackgroundAudioEnabled) return;
    await controller?.evaluateJavascript(
      'if(window.__wsMediaBackground)window.__wsMediaBackground($active);',
    );
  }

  /// Pause every playing media element in the page's main frame (BGAUDIO-009).
  ///
  /// A no-op for sites with [effectiveBackgroundAudioEnabled] — that toggle
  /// exists precisely to keep them sounding. For every other site this is what
  /// makes "Background audio: off" mean anything: neither [pauseWebView] nor
  /// [pauseForAppLifecycle] stops the media pipeline (they freeze JS timers,
  /// see the pause spec), so without it a site the user never opted in for
  /// keeps playing after it loses the screen and holds the OS transport
  /// controls up with it.
  ///
  /// Same ordering constraint as [stopRealCapture]: it must be
  /// dispatched BEFORE the pause, since the iOS per-instance pause blocks the
  /// page's JS thread and this would sit queued behind it. Main frame only
  /// (`evaluateJavascript` targets it) — a player inside a cross-origin
  /// subframe is accepted degradation, as in BGAUDIO-008.
  Future<void> pauseMediaPlayback() async {
    if (effectiveBackgroundAudioEnabled) return;
    await controller?.evaluateJavascript(buildMediaPauseJs());
  }

  /// Resume a previously paused webview when it becomes active again.
  Future<void> resumeWebView() async {
    if (controller == null) return;
    await controller!.resume();
    LogTag.webView.debug(
        'Resumed webview for "$name" (siteId: $siteId)', sensitive: true);
  }

  /// App-lifecycle pause: per-instance pause + process-global JS timer pause.
  ///
  /// The global timer pause is intentional here: when the whole app goes to
  /// background we want every loaded webview's JS frozen, not just the active
  /// one. Pair with [resumeFromAppLifecycle] on resume.
  Future<void> pauseForAppLifecycle() async {
    // Bind both calls to one local controller: disposeWebView() only nulls
    // the `controller` field (the native webview stays alive until the next
    // widget rebuild), so a concurrent dispose landing between these awaits
    // would, if we re-read `controller!`, throw and skip the process-global
    // pauseAllJsTimers — stranding every webview's JS timers. The local keeps
    // both calls on the same still-live controller.
    final c = controller;
    if (c == null) return;
    await c.pause();
    await c.pauseAllJsTimers();
    LogTag.webView.debug(
        'App-lifecycle paused webview for "$name" (siteId: $siteId)',
        sensitive: true);
  }

  /// Inverse of [pauseForAppLifecycle].
  Future<void> resumeFromAppLifecycle() async {
    // See [pauseForAppLifecycle]: bind both calls to one local controller so a
    // concurrent dispose can't strand the process-global resumeAllJsTimers.
    final c = controller;
    if (c == null) return;
    await c.resume();
    await c.resumeAllJsTimers();
    LogTag.webView.debug(
        'App-lifecycle resumed webview for "$name" (siteId: $siteId)',
        sensitive: true);
  }

  /// Dispose the webview and controller to release resources.
  /// Used when unloading a site due to domain conflict.
  void disposeWebView() {
    LogTag.webView.debug(
        'disposeWebView called for "$name" (siteId: $siteId)\n${StackTrace.current}',
        sensitive: true);
    webview = null;
    controller = null;
    resumeReload.reset();
    // The player this site's media session was speaking for is gone with the
    // webview. Without this the OS transport controls outlive it and their
    // buttons reach nothing — a no-op unless this site owns them.
    unawaited(MediaSessionService.instance.stopForSite(siteId));
  }

  /// Drop the in-memory cache (decoded image cache + HTTP response
  /// cache) without disposing the webview. Tab state stays. Used by
  /// the [SiteLifecyclePromotionEngine] cacheCleared tier under OS
  /// memory pressure. Idempotent. No-op when controller is null
  /// (already disposed).
  Future<void> clearWebViewCache() async {
    if (controller == null) return;
    await controller!.clearCache();
    LogTag.webView.debug(
        'Cleared in-memory cache for "$name" (siteId: $siteId)',
        sensitive: true);
  }

  /// User-driven hard reload (pull-to-refresh, Refresh button, Clear-cookies).
  ///
  /// In addition to `controller.reload()`, drop:
  ///   * the [HtmlCacheService] in-memory snapshot for this site, so any
  ///     subsequent webview rebuild before the post-reload save lands
  ///     can't feed the rebuilt webview the stale snapshot the user
  ///     just told us to refresh — bumps the eviction generation, so
  ///     an in-flight save from the disposed view is rejected at write
  ///     time and can't resurrect the dropped bytes;
  ///   * the chromium HTTP/image cache, so the reload actually hits
  ///     the network instead of being satisfied from disk cache (a
  ///     stale-cached HTML response is what bit issue #290 — the user
  ///     pulled to refresh and saw the same stale page because chromium
  ///     served the cached response).
  ///
  /// Online-gated for the HtmlCache eviction: offline users keep the
  /// snapshot as their only renderable content. The HTTP cache clear
  /// runs unconditionally — clearing it offline is harmless (no live
  /// fetch will succeed anyway, and any post-online reload will
  /// repopulate it) and avoids a second connectivity probe on the
  /// hot path.
  Future<void> userDrivenReload() async {
    if (controller == null) return;
    if (_userReloadInFlight) return;
    _userReloadInFlight = true;
    try {
      _beginPendingLoad();
      if (ConnectivityService.instance.lastKnownOnline ?? true) {
        HtmlCacheService.instance.evictInMemory(siteId);
      }
      await clearWebViewCache();
      await reloadAndRepaint();
    } finally {
      _userReloadInFlight = false;
    }
  }

  /// Show the loading bar from the moment the user asks for a reload rather
  /// than from `onLoadStart`. [userDrivenReload] clears the chromium HTTP
  /// cache over a platform channel first, and that round trip is long enough
  /// on a loaded device that the tap reads as ignored — which is what makes a
  /// user tap Refresh again and again on a blank page. `onLoadStart`'s own
  /// `onLoadingChanged(true)` is then deduped by the equality guard, so the
  /// bar does not flicker.
  void _beginPendingLoad() {
    if (isLoading) return;
    isLoading = true;
    loadingProgress = 0;
    stateSetterF?.call();
  }

  /// The single funnel every reload of this site's webview goes through.
  ///
  /// A reload throws away the currently painted compositor frame and commits
  /// a new one an unbounded time later. On Android the hybrid-composition
  /// `SurfaceView` in between is blank, and nothing re-lays it out on its
  /// own, so a reload that recommits slowly leaves a white screen until some
  /// unrelated relayout happens (BUG-001 / PAUSE-021). [onReloadIssued] lets
  /// the host latch the reload and nudge now; the paired [onLoadSettled]
  /// nudges again when the new document actually lands.
  ///
  /// [target] overrides the controller for callers that hold a fresh one
  /// before [controller] is published (the `restoreState` materialize path).
  Future<void> reloadAndRepaint([WebViewController? target]) async {
    final ctrl = target ?? controller;
    if (ctrl == null) return;
    onReloadIssued?.call();
    // No load starts, so clear the bar [_beginPendingLoad] turned on rather
    // than leaving the action button stuck on Stop.
    if (!await ctrl.reload() && isLoading) {
      isLoading = false;
      stateSetterF?.call();
    }
  }

  /// Re-issue a main-frame load that never finished because the app was
  /// backgrounded (PAUSE-022). Loads [url] explicitly rather than calling
  /// `reload()`: the webview may be sitting on a committed error page or on
  /// the *previous* document with the failed navigation already discarded, so
  /// there is nothing reliable to reload. Reports through [onReloadIssued] so
  /// the surface repaint latches exactly as it does for a real reload
  /// (PAUSE-021) — the incoming document lands on the same blank surface.
  Future<void> reissueLoadAndRepaint(String url) async {
    final ctrl = controller;
    if (ctrl == null) return;
    onReloadIssued?.call();
    await ctrl.loadUrl(url, language: language);
  }

  /// User tapped the Stop button. Cancels the in-flight load and
  /// eagerly clears [isLoading] so the URL-bar action button flips
  /// back to Refresh on the next rebuild. `onLoadStop` is not
  /// guaranteed to fire after `stopLoading()` on every engine
  /// (WebKit in particular can swallow it when the cancel races a
  /// commit), which leaves the menu stuck on the Stop icon. The
  /// guard in [onLoadingChanged] suppresses the duplicate rebuild
  /// when the callback does fire.
  Future<void> userStopLoading() async {
    await controller?.stopLoading();
    if (isLoading) {
      isLoading = false;
      stateSetterF?.call();
    }
  }

  /// Capture the WebView's navigation state as bytes. Returns null
  /// when there's nothing to save (controller is null, page never
  /// navigated, or the platform refused). Pair with the matching
  /// `restoreState` on a freshly-created controller in
  /// [getWebView]'s `onControllerCreated` handler to re-hydrate
  /// the back/forward stack and (Apple only) form-field values.
  ///
  /// Live JS heap and DOM are NOT preserved.
  Future<Uint8List?> captureNavigationState() async {
    if (controller == null) return null;
    if (incognito) return null;
    final state = await controller!.saveState();
    if (state == null || state.isEmpty) return null;
    return state;
  }

  /// Current memory-tier state. Drives the
  /// [SiteLifecyclePromotionEngine] cascade. Default [SiteLifecycleState.resident]
  /// — active and paused-but-loaded sites both sit at this tier
  /// (the resume/pause distinction is orthogonal to memory tier).
  /// Promoted on memory pressure events; reset to `live` on
  /// re-activation when the webview is rebuilt.
  SiteLifecycleState lifecycleState = SiteLifecycleState.resident;

  /// Bytes from a prior `controller.saveState()`, queued by the
  /// activation flow when re-activating a [SiteLifecycleState.savedForRestore]
  /// site. Consumed once by [getWebView]'s `onControllerCreated`
  /// handler and then cleared, so subsequent activations don't
  /// re-apply stale state.
  ///
  /// Caller (typically `_setCurrentIndex` in `_WebSpacePageState`)
  /// fetches bytes from [WebViewStateStorage] before letting the
  /// webview rebuild, so the IndexedStack repaint and the
  /// `restoreState` call land in the same render cycle.
  Uint8List? _pendingRestoreState;

  /// Opaque per-site container identifier for archive-tier sites
  /// (ARCH-007). Format mirrors [siteId] (radix-36-dash-radix-36) so a
  /// listing of the on-disk container directory shows uniform-looking
  /// names; the value itself is HMAC-derived from the archive key and
  /// the original siteId. Null for app-tier sites — the normal
  /// `ws-<siteId>` naming continues.
  String? archiveContainerId;

  /// Cookies queued by the archive open flow to be pushed into the
  /// per-site container as soon as the WebView controller exists.
  /// Without this, an archive-tier site that uses native containers
  /// would load with an empty cookie jar even though
  /// [`ArchiveHandle.state.cookies`] holds the user's saved login.
  /// Consumed once by [getWebView]'s `onControllerCreated`.
  List<Cookie>? _pendingArchiveCookies;

  /// Queues [cookies] to be written into the per-site container on the
  /// next WebView construction. Idempotent: caller replaces the queue
  /// each time (e.g. on archive re-open). Setting also seeds
  /// [cookies] so the in-Dart cookie-blocking machinery
  /// (`onCookiesChanged`) starts from the right baseline.
  void setPendingArchiveCookies(List<Cookie> archiveCookies) {
    _pendingArchiveCookies = List<Cookie>.from(archiveCookies);
    cookies = List<Cookie>.from(archiveCookies);
  }

  Future<void> _pushPendingArchiveCookies(WebViewController ctrl) async {
    final pending = _pendingArchiveCookies;
    if (pending == null || pending.isEmpty) return;
    _pendingArchiveCookies = null;
    final mgr = inapp.CookieManager.instance();
    for (final cookie in pending) {
      if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
      final dom = cookie.domain ?? '';
      final cleanDomain = dom.startsWith('.') ? dom.substring(1) : dom;
      if (cleanDomain.isEmpty) continue;
      final path = cookie.path ?? '/';
      // The plugin asserts both are non-empty.
      if (path.isEmpty) continue;
      try {
        await mgr.setCookie(
          url: inapp.WebUri('https://$cleanDomain$path'),
          name: cookie.name,
          value: cookie.value.toString(),
          domain: cookie.domain,
          path: path,
          expiresDate: cookie.expiresDate,
          isSecure: cookie.isSecure,
          isHttpOnly: cookie.isHttpOnly,
          webViewController: ctrl.nativeController,
        );
      } on PlatformException {
        // Best effort. A cookie that fails to insert (malformed
        // attributes from a legacy import, expired, etc.) is simply
        // dropped from the runtime jar; archive state still has it for
        // future round-trips.
      }
    }
  }

  /// Schedule [state] to be applied to the next freshly-created
  /// controller for this model. Cleared automatically once the
  /// `onControllerCreated` callback consumes it.
  void schedulePendingRestoreState(Uint8List state) {
    _pendingRestoreState = state;
  }

  /// Get display name - uses the name field (which auto-updates from page title)
  String getDisplayName() {
    return name;
  }

  // Serialization methods
  ///
  /// The proxy password is never serialised — same contract as
  /// `isSecure=true` cookies, which are also stripped from exports. See
  /// `openspec/specs/proxy-password-secure-storage/spec.md` (PWD-005).
  Map<String, dynamic> toJson() {
    // currentUrl/pageTitle are dropped when either incognito (full ephemeral
    // session — issue #298) or alwaysOpenHome (URL-only ephemeral, cookies
    // persist) is set. Cookies are dropped only by incognito; alwaysOpenHome
    // banking-style sites keep their login state.
    // Both keep the tab list (TAB-009): the site lands on a tab at home
    // without closing the others (TAB-014), and what incognito wipes on a
    // restart is its container and every tab's back stack (INC-002, INC-005).
    // `currentUrl` stays dropped so a build that predates tabs still opens the
    // site at home.
    final dropUrl = incognito || alwaysOpenHome;
    return {
        'siteId': siteId,
        'initUrl': initUrl,
        if (!dropUrl) 'currentUrl': currentUrl,
        if (!tabsAreDefault)
          'tabs': [
            for (final t in tabs)
              {...t.toJson(), if (t.id == activeTabId) 'active': true},
          ],
        'name': name,
        if (!dropUrl) 'pageTitle': pageTitle,
        'cookies': incognito
            ? const <Map<String, dynamic>>[]
            : cookies.map((cookie) => cookie.toJson()).toList(),
        'proxySettings': proxySettings.toJson(),
        'javascriptEnabled': javascriptEnabled,
        'userAgent': userAgent,
        if (uaPreset != null) 'uaPreset': uaPreset!.name,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'httpsUpgradeEnabled': httpsUpgradeEnabled,
        'incognito': incognito,
        'alwaysOpenHome': alwaysOpenHome,
        'kioskMode': kioskMode,
        if (!tabsEnabled) 'tabsEnabled': false,
        if (containerColor != null) 'containerColor': containerColor,
        'language': language,
        if (zoomPercent != kDefaultZoomPercent) 'zoomPercent': zoomPercent,
        'clearUrlEnabled': clearUrlEnabled,
        'dnsBlockEnabled': dnsBlockEnabled,
        'dnsBlockLevel': dnsBlockLevel,
        'disabledFilterLists': disabledFilterLists.toList()..sort(),
        'contentBlockEnabled': contentBlockEnabled,
        'trackingProtectionEnabled': trackingProtectionEnabled,
        'localCdnEnabled': localCdnEnabled,
        if (externalLinkMode != ExternalLinkMode.inApp)
          'externalLinkMode': externalLinkMode.name,
        'fullscreenMode': fullscreenMode,
        if (blockScreenshots) 'blockScreenshots': true,
        if (tabBarButtonCorner != null)
          'tabBarButtonCorner': tabBarButtonCorner!.name,
        'htmlCachingEnabled': htmlCachingEnabled,
        'notificationsEnabled': notificationsEnabled,
        if (backgroundAudioEnabled) 'backgroundAudioEnabled': true,
        if (protectedContentAllowed != null)
          'protectedContentAllowed': protectedContentAllowed,
        // Virtual-source bytes ride the model like `customIconPng` (backups
        // keep them; archive-tier sites live only inside the encrypted slice).
        ...captures.toJson(),
        'userScripts': userScripts.map((s) => s.toJson()).toList(),
        if (enabledGlobalScriptIds.isNotEmpty)
          'enabledGlobalScriptIds': enabledGlobalScriptIds.toList(),
        if (blockedCookies.isNotEmpty)
          'blockedCookies': blockedCookies.map((b) => b.toJson()).toList(),
        'locationMode': locationMode.name,
        if (spoofLatitude != null) 'spoofLatitude': spoofLatitude,
        if (spoofLongitude != null) 'spoofLongitude': spoofLongitude,
        'spoofAccuracy': spoofAccuracy,
        if (spoofTimezone != null) 'spoofTimezone': spoofTimezone,
        if (spoofTimezoneFromLocation) 'spoofTimezoneFromLocation': true,
        if (liveLocationGranularity != LocationGranularity.gps)
          'liveLocationGranularity': liveLocationGranularity.name,
        'webRtcPolicy': webRtcPolicy.name,
        if (letterboxEnabled) 'letterboxEnabled': true,
        if (spoofWindowWidth != null) 'spoofWindowWidth': spoofWindowWidth,
        if (spoofWindowHeight != null) 'spoofWindowHeight': spoofWindowHeight,
        if (fingerprintResetNonce != null)
          'fingerprintResetNonce': fingerprintResetNonce,
        if (customIconPng != null)
          'customIconPng': base64Encode(customIconPng!),
        if (domainClaims != null && domainClaims!.isNotEmpty)
          'domainClaims': domainClaims!.map((c) => c.toJson()).toList(),
        if (routeOutboundLinks) 'routeOutboundLinks': true,
        if (outboundPreferences.isNotEmpty)
          'outboundPreferences':
              outboundPreferences.map((p) => p.toJson()).toList(),
        if (searchAddress != null) 'searchAddress': searchAddress,
        if (searchesWeb) 'searchesWeb': true,
        // Learned from the site's pages, so incognito keeps it in memory.
        if (!incognito && discoveredSearchAddress != null)
          'discoveredSearchAddress': discoveredSearchAddress,
        if (!incognito && discoveredSearchesWeb) 'discoveredSearchesWeb': true,
        if (searchSites.isNotEmpty) 'searchSites': searchSites,
        if (searchDefault != null) 'searchDefault': searchDefault,
      };
  }

  /// A stored level outside 0..5 (hand-edited backup, a future build's
  /// wider range) means "follow the app-wide level" rather than an
  /// out-of-range block posture.
  static int? _readDnsBlockLevel(dynamic raw) {
    if (raw is! int) return null;
    if (raw < kDnsLevelOff || raw > kDnsMaxLevel) return null;
    return raw;
  }

  /// Only `initUrl` is required. Every other field of the wrong type reads
  /// as absent: the startup loader drops a site whose JSON throws and the
  /// next save deletes it, so one odd value (a hand-edited backup, a partial
  /// QR payload, a field a later build retyped) must not cost the whole site.
  factory WebViewModel.fromJson(
    Map<String, dynamic> json,
    Function? stateSetterF, {
    bool isArchiveTier = false,
  }) {
    T? field<T>(String key) {
      final value = json[key];
      return value is T ? value : null;
    }

    num? finite(String key) {
      final value = json[key];
      return value is num && value.isFinite ? value : null;
    }

    final isIncognito = field<bool>('incognito') ?? false;
    final isAlwaysOpenHome = field<bool>('alwaysOpenHome') ?? false;
    // Either flag drops persisted currentUrl/pageTitle on rehydrate; only
    // incognito additionally clears cookies. Defends against legacy JSON
    // written by older builds that didn't strip on toJson.
    final dropUrl = isIncognito || isAlwaysOpenHome;
    final currentUrl = field<String>('currentUrl');
    final rawTabs = field<List<dynamic>>('tabs');
    final userAgent = field<String>('userAgent') ?? '';
    final proxy = json['proxySettings'];
    final model = WebViewModel(
      // Validate against path-safe format: a crafted backup could otherwise
      // set siteId to `../…` and escape the cache/import/storage keyspace.
      // null (missing or unsafe) auto-generates a fresh id.
      siteId: sanitizedSiteId(json['siteId']),
      initUrl: migrateLegacyFileImportUrl(json['initUrl'] as String),
      currentUrl: dropUrl || currentUrl == null
          ? null
          : migrateLegacyFileImportUrl(currentUrl),
      // JSON without `tabs` is a site written before tabs existed, or one that
      // never opened a second tab: the constructor synthesises the primary tab
      // from `currentUrl`. A list that is present is authoritative, and
      // `currentUrl`/`pageTitle` beside it are only the copy older builds read.
      // Entries that cannot name a tab are dropped rather than sinking the site.
      tabs: rawTabs
          ?.map(SiteTab.fromJson)
          .whereType<SiteTab>()
          .map((t) => t..url = migrateLegacyFileImportUrl(t.url))
          .toList(),
      activeTabId: SiteTab.activeIdIn(rawTabs),
      name: field<String>('name'),
      cookies: isIncognito
          ? const <Cookie>[]
          : _jsonEntries(json['cookies'], tryCookieFromJson),
      proxySettings: proxy is Map
          ? UserProxySettings.fromJson(Map<String, dynamic>.from(proxy))
          : null,
      javascriptEnabled: field<bool>('javascriptEnabled') ?? true,
      // Migration: a stored string that is a stock webview-default shape is
      // a frozen snapshot of the device default (old settings-screen builds
      // pre-filled the field with the default and persisted it on save).
      // Drop the override so the site tracks the live default again.
      userAgent: isStockWebViewDefaultUserAgent(userAgent) ? '' : userAgent,
      // Migration: legacy data carries only the rendered string. A string
      // matching a generated shape (including shapes old buggy builds
      // emitted) gets its preset back here, so stale persisted UAs heal on
      // load instead of rotting until a site breaks on them.
      uaPreset: userAgentPresetFromName(field<String>('uaPreset')) ??
          recognizeGeneratedUserAgent(userAgent),
      thirdPartyCookiesEnabled: field<bool>('thirdPartyCookiesEnabled') ?? false,
      httpsUpgradeEnabled: field<bool>('httpsUpgradeEnabled'),
      incognito: isIncognito,
      alwaysOpenHome: isAlwaysOpenHome,
      kioskMode: field<bool>('kioskMode') ?? false,
      tabsEnabled: field<bool>('tabsEnabled') ?? true,
      containerColor: switch (field<int>('containerColor')) {
        final int i when i >= 0 => i,
        _ => null,
      },
      language: sanitizedLanguageTag(json['language']),
      zoomPercent: clampZoomPercent(
          finite('zoomPercent')?.toInt() ?? kDefaultZoomPercent),
      clearUrlEnabled: field<bool>('clearUrlEnabled') ?? true,
      dnsBlockEnabled: field<bool>('dnsBlockEnabled') ?? true,
      dnsBlockLevel: _readDnsBlockLevel(json['dnsBlockLevel']),
      disabledFilterLists: {
        for (final id in field<List>('disabledFilterLists') ?? const [])
          if (id is String) id
      },
      contentBlockEnabled: field<bool>('contentBlockEnabled') ?? true,
      trackingProtectionEnabled:
          field<bool>('trackingProtectionEnabled') ?? true,
      localCdnEnabled: field<bool>('localCdnEnabled') ?? true,
      // `externalLinksInBrowser` is the bool this field replaced.
      externalLinkMode: externalLinkModeFromJson(
          json['externalLinkMode'], json['externalLinksInBrowser']),
      fullscreenMode: field<bool>('fullscreenMode') ?? false,
      blockScreenshots: field<bool>('blockScreenshots') ?? false,
      // `tabBarButtonOnRight` is the short-lived bool predecessor of the
      // four-corner field; map it so early builds rehydrate cleanly.
      tabBarButtonCorner:
          tabBarCornerFromName(field<String>('tabBarButtonCorner')) ??
              switch (field<bool>('tabBarButtonOnRight')) {
                null => null,
                true => TabBarCorner.bottomRight,
                false => TabBarCorner.bottomLeft,
              },
      htmlCachingEnabled: field<bool>('htmlCachingEnabled') ?? false,
      notificationsEnabled: field<bool>('notificationsEnabled') ??
          field<bool>('backgroundPoll') ??
          false,
      backgroundAudioEnabled: field<bool>('backgroundAudioEnabled') ?? false,
      protectedContentAllowed: field<bool>('protectedContentAllowed'),
      captures: CaptureGrants.fromJson(json),
      userScripts:
          _jsonEntries(json['userScripts'], UserScriptConfig.fromJson),
      enabledGlobalScriptIds: {
        for (final id in field<List>('enabledGlobalScriptIds') ?? const [])
          if (id is String) id
      },
      blockedCookies:
          _jsonEntries(json['blockedCookies'], BlockedCookie.tryFromJson).toSet(),
      locationMode: LocationMode.values.firstWhere(
        (m) => m.name == json['locationMode'],
        orElse: () => LocationMode.off,
      ),
      spoofLatitude: finite('spoofLatitude')?.toDouble(),
      spoofLongitude: finite('spoofLongitude')?.toDouble(),
      spoofAccuracy:
          finite('spoofAccuracy')?.toDouble() ?? kDefaultSpoofAccuracy,
      spoofTimezone: field<String>('spoofTimezone'),
      spoofTimezoneFromLocation:
          field<bool>('spoofTimezoneFromLocation') ?? false,
      liveLocationGranularity: _decodeLiveLocationGranularity(
          json['liveLocationGranularity']),
      webRtcPolicy: WebRtcPolicy.values.firstWhere(
        (p) => p.name == json['webRtcPolicy'],
        orElse: () => WebRtcPolicy.defaultPolicy,
      ),
      letterboxEnabled: field<bool>('letterboxEnabled') ?? false,
      spoofWindowWidth: finite('spoofWindowWidth')?.toInt(),
      spoofWindowHeight: finite('spoofWindowHeight')?.toInt(),
      fingerprintResetNonce: field<String>('fingerprintResetNonce'),
      customIconPng: _decodeCustomIconPng(json['customIconPng']),
      // Absent stays null: no claims configured, as opposed to an emptied list.
      domainClaims: json['domainClaims'] is List
          ? [
              for (final claim
                  in _jsonEntries(json['domainClaims'], DomainClaim.tryFromJson))
                if (claim.value.isNotEmpty) claim,
            ]
          : null,
      routeOutboundLinks: field<bool>('routeOutboundLinks') ?? false,
      outboundPreferences: OutboundPreference.dedupedByClaim(
        (field<List<dynamic>>('outboundPreferences') ?? const [])
            .map(OutboundPreference.fromJson)
            .whereType<OutboundPreference>(),
      ),
      searchAddress: field<String>('searchAddress'),
      searchesWeb: field<bool>('searchesWeb') ?? false,
      discoveredSearchAddress: field<String>('discoveredSearchAddress'),
      discoveredSearchesWeb: field<bool>('discoveredSearchesWeb') ?? false,
      searchSites: [
        for (final id in field<List<dynamic>>('searchSites') ?? const [])
          if (sanitizedSiteId(id) case final String safe) safe,
      ],
      searchDefault: sanitizedSiteId(json['searchDefault']),
      stateSetterF: stateSetterF,
      isArchiveTier: isArchiveTier,
    )..pageTitle ??= dropUrl ? null : field<String>('pageTitle');
    // Loading a site is a fresh entry to it, so an always-home site lands at
    // home here (AOH-002, TAB-014), before anything can build its webview.
    if (isAlwaysOpenHome && !isIncognito) {
      model.landAtHome(
        tabsOn: model.effectiveTabsEnabled &&
            ExperimentalFeaturesService.instance
                .isEnabled(ExperimentalFeature.siteTabs),
      );
    }
    return model;
  }
}

/// The entries of a JSON list that [parse] accepts. A malformed entry (a
/// cookie, a script, a claim) is dropped rather than failing its site.
List<T> _jsonEntries<T extends Object>(
  Object? raw,
  T? Function(Map<String, dynamic>) parse,
) =>
    raw is List
        ? [
            for (final entry in raw)
              if (entry is Map<String, dynamic>) ?parse(entry),
          ]
        : <T>[];

bool _onePerClaim(List<OutboundPreference> prefs) =>
    prefs.map((p) => p.claim).toSet().length == prefs.length;

Uint8List? _decodeCustomIconPng(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return base64Decode(raw);
  } on FormatException {
    return null;
  }
}

/// Legacy enum values written before the three-tier rename are migrated:
/// `"fine"` (pre-#326 default = raw GPS) → [LocationGranularity.gps],
/// `"coarse"` (pre-#326 cell-tower-only) → [LocationGranularity.gsm].
/// Anything unrecognised or absent falls through to [LocationGranularity.gps].
LocationGranularity _decodeLiveLocationGranularity(Object? raw) {
  if (raw is String) {
    if (raw == 'fine') return LocationGranularity.gps;
    if (raw == 'coarse') return LocationGranularity.gsm;
    for (final v in LocationGranularity.values) {
      if (v.name == raw) return v;
    }
  }
  return LocationGranularity.gps;
}
