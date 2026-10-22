import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/step_table.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:webspace/settings/filter_list_id.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show WebUri;
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/opensearch_engine.dart'
    show SiteSearchTarget;
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/user_agent_preset.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/web_view_model_search.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/services/webview_tab_binding.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/webview_proxy.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/web_view_model_json.dart';
import 'package:webspace/web_view_model_domains.dart';
import 'package:webspace/web_view_model_zone.dart';
import 'package:webspace/services/anti_fingerprinting_shim.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/settings/blocked_cookie.dart';
import 'package:webspace/services/page_js.dart';

export 'package:webspace/web_view_model_domains.dart';
export 'package:webspace/services/url_host.dart'
    show extractDomain, getBaseDomain, getNormalizedDomain;
export 'package:webspace/settings/blocked_cookie.dart';
export 'package:webspace/settings/location.dart'
    show LocationMode, LocationGranularity, WebRtcPolicy;

class WebViewModel implements MediaGrantRecord {
  final SiteId siteId;
  String initUrl;

  /// This site's tabs, in tree order (a child follows its parent). Never
  /// empty. Exactly one of them — [activeTabId] — is bound to the site's
  /// single webview; the rest are parked and hold no renderer. See
  /// [lib/services/site_tab.dart] and TAB-001/TAB-002. The model's `tabs`,
  /// written only through [tabsCell].
  List<SiteTab> get tabs => _tabs;
  late List<SiteTab> _tabs;

  /// The tab the site's webview is showing. Always names a member of
  /// [tabs]. The model's `active`, written only through [activeTabCell].
  TabId get activeTabId => _activeTabId;
  late TabId _activeTabId;

  static final tabsCell = SharedAt<WebViewModel, List<SiteTab>>(
    ModelVar.tabs,
    read: (m) => m._tabs,
    write: (m, {required to}) => m._tabs = to,
    members: (tabs) => {for (final t in tabs) t.id},
  );
  static final activeTabCell = SharedAt<WebViewModel, TabId>(
    ModelVar.active,
    read: (m) => m._activeTabId,
    write: (m, {required to}) => m._activeTabId = to,
  );

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
  static WebViewModel? Function(SiteId siteId)? siteLookup;

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

  /// The site each tab runs as, the model's `host[s]`.
  Map<TabId, WebViewModel> get tabHosts =>
      TabHosts({for (final t in tabs) t.id: hostOf(t) ?? this}, site: this);

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

  String stateKeyForTab(TabId tabId) {
    final tab = tabs.where((t) => t.id == tabId).firstOrNull;
    return webViewStateKey(tab?.hostSiteId ?? siteId, tabId: tabId);
  }

  /// Whether the active tab's back stack may be written (LIR-022): its record
  /// persists with this site's tab list, and the site it runs as keeps state.
  bool get activeTabPersistsNavState => tabPersistsNavState(activeTab);

  /// Whether [tab]'s back stack may be written: as
  /// [activeTabPersistsNavState], for any tab of this site.
  bool tabPersistsNavState(SiteTab tab) {
    if (!persistsNavState) return false;
    if (tab.hostSiteId == null) return true;
    final host = hostOf(tab);
    return host != null && host.persistsNavState;
  }

  /// Whether [tabs] is still exactly what a site that never opened a second
  /// tab carries. Serialisation omits the list while this holds, so on-disk
  /// output is unchanged for those users (same rule as `domainClaims`).
  bool get tabsAreDefault =>
      tabs.length == 1 &&
      tabs.single.id == kPrimaryTabId &&
      tabs.single.parentId == null;

  /// Null follows the app-wide Tabs choice (TAB-013). Read [effectiveTabsEnabled]
  /// instead: a kiosk site runs as one page whatever this stores, and the
  /// stored value comes back when Kiosk mode is turned off.
  bool? tabsEnabled;

  /// A kiosk site runs as one page, never with tabs (TAB-013). Turning tabs
  /// off this way keeps the tab list, as the app-wide switch does (TAB-012).
  bool get effectiveTabsEnabled => resolveTabs(
      tabs: Scoped.fromStored(tabsEnabled).resolve(AppPref.tabsEnabled.value),
      kiosk: kioskMode);

  /// The colour this site's container is drawn in, as an index into the
  /// container palette (TAB-018). Given once, when the site first needs one,
  /// and kept; null until then.
  int? containerColor;

  /// The palette index the container is drawn in: [containerColor], or the
  /// one derived from the siteId until it is given.
  int get drawnContainerColor =>
      containerColor ??
      ContainerColorEngine.fallback(siteId, paletteSize: kContainerPaletteSize);

  /// Put a site that has no webview yet on a tab at its home page, as Always
  /// open Home asks of every fresh entry (TAB-014). With tabs the tab it was on
  /// stays in the list; without, that tab is sent home. Only the JSON read
  /// does this, to a model no runtime holds yet ([fresh]), so it sets the
  /// state the model starts in, as the constructor does.
  void landAtHome({required Unpublished fresh}) {
    if (effectiveTabsEnabled) {
      final landing = TabLifecycleEngine.homeLanding(tabs,
          activeTabId: activeTabId, initUrl: initUrl);
      if (landing == null) return;
      _tabs = landing.tabs;
      _activeTabId = landing.activeTabId;
      return;
    }
    if (_ownerRunTab() case (:final tabs, :final active)) {
      _tabs = tabs;
      _activeTabId = active;
      activeTab.lastActiveAt = DateTime.now();
    }
    if (currentUrl == initUrl) return;
    currentUrl = initUrl;
    pageTitle = null;
  }

  /// LIR-018: before an owner URL loads, move a site with no live webview from
  /// a hosted tab to one it runs itself: the nearest such ancestor, or a new
  /// root tab at home. A live slot moves through a tab switch instead.
  void bindOwnerRunTab() {
    if (_ownerRunTab() case (:final tabs, :final active)) {
      const commit = Commit.unmodeled(Unmodeled.ownerRunTab);
      if (!identical(tabs, _tabs)) {
        tabsCell.write(at: this, to: tabs, commit: commit);
      }
      activeTabCell.write(at: this, to: active, commit: commit);
      activeTab.lastActiveAt = DateTime.now();
    }
  }

  ({List<SiteTab> tabs, TabId active})? _ownerRunTab() =>
      TabLifecycleEngine.ownerRunMove(_tabs,
          activeTabId: activeTabId, homeUrl: initUrl, isForeign: isForeignTab);

  String name;
  List<Cookie> cookies;
  Widget? webview;
  /// The last main-frame navigation this site's webview refused to make
  /// because the app could not establish that it would go through the site's
  /// proxy (LEAK-010), or because it named an onion service and the site has
  /// none (LEAK-016). Drives the interstitial over the page; deliberately not
  /// persisted, since it describes one navigation and not the site.
  BlockedNavigation? blockedNavigation;
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
  WebViewTheme? theme; // Color scheme pages are told to prefer, null = app's (HINTS-006)
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
  Set<FilterListId> disabledFilterLists;

  /// Both blocker masks are dropped for archive-tier sites (ARCH-006). Each
  /// leaves a trace outside the archive's keyspace whose presence would
  /// betray that an archive exists: a per-site level pins a downloaded level
  /// file, and a per-site list selection rewrites the shared engine cache
  /// blob. Archive sites run the app-wide posture instead.
  int? get effectiveDnsBlockLevel =>
      ArchiveFold.dnsBlockLevel(dnsBlockLevel, archived: isArchiveTier);

  Set<FilterListId> get effectiveDisabledFilterLists => ArchiveFold.disabledFilterLists(
      disabledFilterLists, archived: isArchiveTier);
  /// Umbrella per-site Enhanced Tracking Protection: when true, applies
  /// the anti-fingerprinting JS shim (Canvas/WebGL/audio/fonts/screen/
  /// hardware/timing) AND forces clearUrlEnabled, dnsBlockEnabled, and
  /// contentBlockEnabled to behave as on regardless of their own value.
  /// When false, the three sub-toggles act independently.
  bool trackingProtectionEnabled;
  bool localCdnEnabled; // Serve CDN resources from local cache for privacy
  /// Where a cross-domain link that is not covered by this site's domain
  /// claims goes: null follows the app, otherwise a nested webview, the browser
  /// (discussion #438) or nowhere (issue #629). Links to claimed domains
  /// open in-app in every mode.
  ExternalLinkMode? externalLinkMode;
  bool fullscreenMode; // Auto-enter fullscreen when this site is selected
  /// While this site is on screen, the window is withheld from screenshots,
  /// recordings and the recent-apps preview (SCREENBLOCK-002). Android only;
  /// the value is kept elsewhere so a backup restored there still carries it.
  bool blockScreenshots;
  /// Corner the floating tab-bar button rests in while this site is
  /// active. Set by dragging the button itself; null = never dragged,
  /// falls back to the app-wide default.
  TabBarCorner? tabBarButtonCorner;
  /// When true, every start takes the first page from the engine's own
  /// HTTP cache and then reloads it live once the network answers. When
  /// false, only a start the last probe found offline does
  /// (`loadsCacheFirst`).
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
  List<UserScriptConfig> userScripts;
  /// IDs of global user scripts opted into for this site. Global scripts
  /// are stored once in app state (shared source/URL) and each site
  /// independently enables which ones to inject.
  Set<UserScriptId> enabledGlobalScriptIds;
  Set<BlockedCookie> blockedCookies;
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
  /// Homepage suggestions already shown per domain, including declines, so
  /// prompts do not repeat on refresh, tab recreation, or an app restart.
  Set<DomainClaim> offeredRedirectDomains = {};

  /// Outbound routing (LIR-013): a cross-domain link this site opens goes to
  /// the site that claims it, with that site's container and settings,
  /// instead of a nested screen with this site's own. External-link inheritance
  /// uses the app's routing policy while retaining this explicit choice.
  bool routeOutboundLinks;

  /// This site's own routing rules, consulted before the global claims
  /// (LIR-014).
  List<OutboundPreference> get outboundPreferences => _outboundPreferences;
  set outboundPreferences(List<OutboundPreference> value) {
    assert(OutboundPreference.onePerClaim(value),
        'at most one outbound preference per claim');
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

  /// The search sites a search from this site offers; empty offers them all.
  List<SiteId> searchSites;

  /// The search site a search from this site starts with; null falls back to
  /// the app default.
  SiteId? searchDefault;

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
        frame: NavigationFrame.top,
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
  bool get effectiveNotificationsEnabled => ArchiveFold.notifications(
      stored: notificationsEnabled, archived: isArchiveTier);

  /// Effective background-audio enable. Archive-tier sites never opt out
  /// of lifecycle pausing: audibly playing while the app looks idle (and
  /// surfacing in the OS now-playing UI) would reveal an open archive
  /// (ARCH-006).
  bool get effectiveBackgroundAudioEnabled => ArchiveFold.backgroundAudio(
      stored: backgroundAudioEnabled, archived: isArchiveTier);

  /// Forced on by Tracking Protection (ETP-002), but the archive fold comes
  /// last: an archive-tier site never uses LocalCDN (ARCH-006).
  bool get effectiveLocalCdnEnabled => ArchiveFold.localCdn(
      stored: _forcedByTrackingProtection(
          TrackingProtectionForce.localCdn, stored: localCdnEnabled),
      archived: isArchiveTier);

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
      ArchiveFold.incognito(stored: incognito, archived: isArchiveTier);

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
      _forcedByTrackingProtection(TrackingProtectionForce.thirdPartyCookies,
          stored: thirdPartyCookiesEnabled);

  /// Effective HTTPS upgrade decision. Tracking Protection forces it on
  /// (ETP-030); otherwise the site's own override, or the app-wide default
  /// when it has none. Unlike ETP-002's subordinates this is NOT off when the
  /// umbrella is off: turning the umbrella off to make a site work must not be
  /// what moves a login page to cleartext.
  bool get effectiveHttpsUpgradeEnabled => _forcedByTrackingProtection(
      TrackingProtectionForce.httpsUpgrade,
      stored: Scoped.fromStored(httpsUpgradeEnabled)
          .resolve(AppPref.httpsUpgradeEnabled.value));

  bool _forcedByTrackingProtection(TrackingProtectionForce force,
          {required bool stored}) =>
      force.resolve(
          stored: stored, trackingProtection: trackingProtectionEnabled);

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
      stored: protectedContentAllowed,
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
      ArchiveFold.externalLinks(
          Scoped.fromStored(externalLinkMode).resolve(ExternalLinkMode.appDefault),
          archived: isArchiveTier);

  /// Outbound routing is an option of the in-app mode (LIR-014): in any
  /// other mode the switch is hidden and its stored value inert.
  bool get effectiveRouteOutboundLinks => resolveRouteOutboundLinks(
      route: routeOutboundLinks,
      appRoute: AppPref.routeOutboundLinks.value,
      followsAppLinks: externalLinkMode == null,
      mode: effectiveExternalLinkMode);

  /// The native container this site's webview binds under [isolation], as
  /// its posture and its site info sheet name it (NAV-011).
  ContainerName? boundContainerId(Isolation isolation) => containerIdFor(
      isolation: isolation, key: containerKey, incognito: effectiveIncognito);

  /// Everything a webview that runs as this site applies (CLAUDE.md, "Per-site
  /// settings MUST apply to nested webviews"). The archive tier's overrides
  /// come from the `effective*` getters above; Tracking Protection's forced
  /// subordinates are applied here, by the rules in site_overrides.dart
  /// (ETP-002). Read at the moment a surface is built, so a link opened later
  /// carries the decisions made since. [globalUserScripts] is the app's list,
  /// of which the site opts into some; [isolation] decides its container.
  SitePosture sitePosture({
    required List<UserScriptConfig> globalUserScripts,
    required Isolation isolation,
  }) {
    assert(zoneLookedUp, 'a webview at the real zone: none was looked up');
    final tp = trackingProtectionEnabled;
    bool forced(TrackingProtectionForce force, {required bool stored}) =>
        _forcedByTrackingProtection(force, stored: stored);
    return SitePosture(
      siteId: siteId,
      container: (
        containerId: boundContainerId(isolation),
        incognito: effectiveIncognito,
        proxy: outboundProxySettings,
        thirdPartyCookies: effectiveThirdPartyCookiesEnabled,
        httpAuthMemory: effectiveHttpAuthMemory,
        passkeys: effectivePasskeysEnabled,
      ),
      blocking: (
        clearUrls: forced(TrackingProtectionForce.clearUrls, stored: clearUrlEnabled),
        dns: forced(TrackingProtectionForce.dnsBlock, stored: dnsBlockEnabled),
        dnsLevel: effectiveDnsBlockLevel,
        contentBlock:
            forced(TrackingProtectionForce.contentBlock, stored: contentBlockEnabled),
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
        theme: effectiveTheme,
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
  /// this model (cold start, `goHome` recreate, renderer-gone recovery,
  /// savedForRestore re-creation). The host uses it to recomposite the
  /// Android hybrid-composition surface, which can re-attach blank-white
  /// when a new platform view mounts. Re-activation of an already-loaded
  /// webview does NOT recreate the controller, so it does not fire here —
  /// that path is nudged explicitly by `activate`.
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

  /// Completes when this site's first main-frame load settles, loaded or
  /// failed. A webview disposed before then leaves it pending.
  Future<void> get firstLoadSettled => _firstLoadSettled.future;
  final Completer<void> _firstLoadSettled = Completer<void>();

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
  /// The app's theme as the page last handed it over, set before the first
  /// build (the light default would otherwise flash a file import's prelude).
  WebViewTheme _appTheme = WebViewTheme.light;

  /// What this site's pages are told to prefer: its own [theme], else the
  /// app's. A file import's prelude reads it to paint a matching first frame.
  WebViewTheme get effectiveTheme => Scoped.fromStored(theme).resolve(_appTheme);

  /// The UA string webviews are actually built with: presets render fresh
  /// at the current Firefox version; custom strings pass through verbatim.
  String get effectiveUserAgent => uaPreset == null
      ? userAgent
      : renderUserAgentPreset(
          uaPreset!, version: FirefoxUserAgentService.instance.versionString);

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
    SiteId? siteId,
    required this.initUrl,
    String? currentUrl,
    List<SiteTab>? tabs,
    TabId? activeTabId,
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
    this.tabsEnabled,
    this.containerColor,
    this.language,
    this.zoomPercent = kDefaultZoomPercent,
    this.theme,
    this.clearUrlEnabled = true,
    this.dnsBlockEnabled = true,
    this.dnsBlockLevel,
    this.contentBlockEnabled = true,
    this.disabledFilterLists = const <FilterListId>{},
    this.trackingProtectionEnabled = true,
    this.localCdnEnabled = true,
    this.externalLinkMode,
    this.fullscreenMode = false,
    this.blockScreenshots = false,
    this.tabBarButtonCorner,
    this.htmlCachingEnabled = false,
    this.notificationsEnabled = false,
    this.backgroundAudioEnabled = false,
    this.protectedContentAllowed,
    this.captures = CaptureGrants.none,
    List<UserScriptConfig>? userScripts,
    Set<UserScriptId>? enabledGlobalScriptIds,
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
    List<SiteId>? searchSites,
    this.searchDefault,
    this.stateSetterF,
    this.isArchiveTier = false,
  })  : assert(OutboundPreference.onePerClaim(outboundPreferences ?? const []),
            'at most one outbound preference per claim'),
        userScripts = userScripts ?? [],
        _outboundPreferences = outboundPreferences ?? [],
        searchSites = searchSites ?? [],
        enabledGlobalScriptIds = enabledGlobalScriptIds ?? {},
        blockedCookies = blockedCookies ?? {},
        siteId = siteId ?? SiteId.mint(),
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
      activeTabId: activeTabId,
      fallbackUrl: currentUrl ?? initUrl,
    );
    _tabs = seeded.tabs;
    _activeTabId = seeded.activeTabId;
    for (final t in _tabs) {
      t.ownedBy(this.siteId);
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

  bool isCookieBlocked(String name, {required String? domain}) =>
      matchesBlockedCookie(blockedCookies, name: name, domain: domain);

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
  ContainerName? _containerProxyToRelease;

  Future<void> setController() async {
    if (controller == null) {
      return;
    }
    // Read before the first await: onControllerCreated consumes the pending
    // restore right after calling us, and that path issues its own load.
    final restorePending = tabBinding.queuedFor == tabBinding.built;
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
    await c.setThemePreference(effectiveTheme);
    defaultUserAgent ??= await HostBrowser.sentUserAgent();
  }

  /// What this slot's own webview claims of the process-wide proxy rule: its
  /// occupant, running as the site whose proxy and Tor tag it takes
  /// (LIR-024).
  ({RouteOccupant occupant, WebViewModel runsAs}) get routeClaim =>
      (occupant: (use: RouteUse.webview, site: siteId), runsAs: runningIdentity);

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
    final (:occupant, :runsAs) = routeClaim;
    try {
      await proxyManager.setProxySettings(
        runsAs.proxySettings,
        siteId: runsAs.siteId,
        occupant: occupant,
      );
      final release = _containerProxyToRelease;
      _containerProxyToRelease = null;
      if (release != null) await proxyManager.releaseContainerProxy(release);
      return true;
    } on ProxyRefused catch (e) {
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
      if (resolveEffectiveProxy(runsAs.proxySettings, siteId: runsAs.siteId)
              .type !=
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
      for (final g in globalUserScripts)
        if (enabledGlobalScriptIds.contains(g.id)) g.asEnabled(),
      ...userScripts,
    ];
  }

  Future<void> setAppTheme(WebViewTheme appTheme) async {
    _appTheme = appTheme;
    if (webview != null) await controller?.setThemePreference(effectiveTheme);
  }

  /// On iOS / macOS, the proxy is sealed into the per-site
  /// `WKWebsiteDataStore` at WebView construction time. To pick up the
  /// new value, the live WebView is discarded so the next render
  /// reconstructs it with the new `inapp.InAppWebViewSettings.proxySettings`
  /// dictionary. The caller MUST trigger a rebuild (typically via
  /// `setState`) so the IndexedStack actually re-creates the slot.
  ///
  /// Elsewhere only a live webview takes the new rule now; one built later
  /// takes it then, so a site with none never moves the process-wide rule
  /// under the sites that run (PROXY-008).
  Future<void> updateProxySettings(UserProxySettings newSettings) async {
    proxySettings = newSettings;
    if (hostIsIOS || hostIsMacOS) {
      disposeWebView(commit: const Commit.unmodeled(Unmodeled.rebuild));
      return;
    }
    if (controller != null) await _applyProxySettings();
  }

  /// The site as itself, at its home page, for a headless check in a
  /// background wake (NOTIF-016). Built from the same [sitePosture] as
  /// [getWebView]'s config, so every per-site field reaches the check, under
  /// [hooks] that answer no one: nothing is on screen.
  WebViewConfig headlessCheckConfig(WebViewHostHooks hooks) => WebViewConfig(
        posture: sitePosture(
            globalUserScripts: hooks.globalUserScripts(), isolation: hooks.isolation()),
        hooks: hooks.unattended(),
        initialUrl: initUrl,
        cacheFirst: false,
      );

  /// The slot's webview, built on first call; null while the site waits for
  /// Tor (TOR-008). [initialHtml] is a file import's page; [cacheFirst] takes
  /// the first page from the engine's cache, then loads it live
  /// (`loadsCacheFirst`).
  Widget? getWebView(
    WebViewHostHooks hooks, {
    required bool cacheFirst,
    String? initialHtml,
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
bool dispatch(NavigationDecision decision,
    {required String url, required bool hadGesture, required String via}) {
      LogTag.webView.debug('$via -> ${decision.name} $url', sensitive: true);
      if (NavigationDecisionEngine.stepFor(decision,
              returnsToOwner: returnsToOwner(url)) ==
          NavigationStep.returnToOwner) {
        onReturnToOwner?.call(url);
        return false;
      }
      bool takenOver() => hooks.routeOutbound(this, url: url, decision: decision, hadGesture: hadGesture);
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
              posture: id.sitePosture(
                  globalUserScripts: globalUserScripts, isolation: hooks.isolation()),
              homeTitle: id.name,
            );
          }
          return false;
        case NavigationDecision.blockOpenExternal:
          if (!takenOver()) unawaited(hooks.openInBrowser(url));
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
      final builtTab = activeTabId;
      tabBinding.bind(builtTab, commit: const Commit.environment(Environment.frame));
      LogTag.webView.debug(
          'Creating webview for "$name" (siteId: $siteId, initUrl: $initUrl'
          '${hosted ? ', running as ${id.siteId}' : ''})', sensitive: true);
      LogTag.webView.debug(
          'First page: ${initialHtml != null ? 'import' : cacheFirst ? 'cache first' : 'live'}',
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
      final navigationBoundary =
          NavigationBoundary(homeUrl: navHome, initialUrl: currentUrl);
      if (tabBinding.queuedFor == builtTab) {
        navigationBoundary.useExistingDocument();
      }
      // The URL we most recently fired the post-state-commit IPC chain
      // (`getTitle` + `setThemePreference`) for. `onUrlChanged` is wired
      // up to BOTH `onLoadStop` and `onUpdateVisitedHistory` in
      // webview.dart, so a single navigation reliably produces two
      // events with the same URL — without dedup we'd post 2× getTitle
      // + 2× evaluateJavascript IPCs per navigation, doubling the
      // race-window count for the chromium dangling-raw_ptr crash.
      String? lastNotifiedUrl;
      String? lastSavedUrl;
      // Android restore ordering: when nav-state bytes are queued for this
      // build, the webview must apply restoreState to a pristine back/forward
      // list. Suppress the initial load on Android and materialize the
      // restored entry from onControllerCreated; iOS/macOS keep the
      // initialUrlRequest load and replace state in place via interactionState.
      final bool deferRestoreLoad = deferInitialLoadForRestore(
        hasPendingRestoreState: tabBinding.queuedFor == builtTab,
        isAndroid: hostIsAndroid,
        isFileImport: currentUrl.startsWith('file://'),
      );
      final posture = id.sitePosture(
          globalUserScripts: globalUserScripts, isolation: hooks.isolation());
      final storeBinding = WebViewFactory.storeBinding(posture);
      // A first load the route refuses restores nothing either: the queued
      // back stack is still taken, and dropped, since replaying it would
      // load what the factory just refused (LEAK-016).
      final restores =
          WebViewFactory.refusesLoad(storeBinding, url: currentUrl) == null;
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
          navigationBoundary: navigationBoundary,
          onFirstPageLoaded: (url) {
            if (activeTabId == builtTab && !runsForeignTab && currentUrl == url) {
              hooks.firstPageLoaded(this, url: url);
            }
          },
          // Root site webview sits at the MaterialApp root route: on iOS/macOS
          // there is no Flutter route-pop edge-swipe here, so opt into
          // WKWebView's native back/forward swipe. Nested screens don't (NAV-008).
          backForwardGestures: true,
          deferInitialLoad: deferRestoreLoad || deferForProxy,
          backgroundAudioEnabled: effectiveBackgroundAudioEnabled,
          onLinkLongPress: (url) => hooks.linkMenu(this, url: url),
          grants: PersistedGrantStore(
            id,
            prompter: hooks.media,
            isSiteActive: isActive,
            save: hooks.save,
          ),
          pullToRefreshGate: pullToRefreshGate,
          onUnproxiedNavigationBlocked: (blocked) {
            blockedNavigation = blocked;
            hooks.rebuild();
          },
          shouldOverrideUrlLoading: (url, {required hasGesture, required frame}) {
            LogTag.webView.debug(
                'shouldOverrideUrlLoading: site="$name" (siteId: $siteId) initUrl=$initUrl request=$url hasGesture=$hasGesture',
                sensitive: true);
            final now = DateTime.now();
            final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
              targetUrl: url,
              initUrl: navHome,
              hasGesture: hasGesture,
              frame: frame,
              isSiteActive: isActive(),
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: now,
              externalLinkMode: id.effectiveExternalLinkMode,
              matchesSiteClaim: navClaim,
              boundary: navigationBoundary,
            );
            lastSameDomainGestureTime = result.gestureUpdate
                .applyTo(lastSameDomainGestureTime, now: now);
            return dispatch(result.decision,
                url: url,
                hadGesture: result.hadGesture,
                via: 'shouldOverrideUrlLoading');
          },
          onReloadIssued: () => onReloadIssued?.call(),
          onMainFrameLoad: resumeReload.noteLoad,
          onLoadingChanged: ({required loading}) {
            if (isLoading == loading) return;
            isLoading = loading;
            // Reset on start so the bar doesn't flash the previous
            // navigation's near-complete value.
            if (loading) loadingProgress = 0;
            // A settled load is the reloaded document committing onto the
            // surface; the host repaints there rather than at reload-issue
            // time, when there is nothing yet to paint (PAUSE-021).
            if (!loading) {
              if (!_firstLoadSettled.isCompleted) _firstLoadSettled.complete();
              onLoadSettled?.call();
            }
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
              boundary: navigationBoundary,
            );
            lastSameDomainGestureTime = handled.gestureUpdate
                .applyTo(lastSameDomainGestureTime, now: now);
            urlChangedState = handled.state;
            // No navigate-back to the last same-domain page: even
            // stopLoading + microtask + loadUrl(prev) races Chromium's
            // in-flight cross-origin redirect on the Android WebView build
            // that SIGTRAPs at `partition_alloc_support.cc:770` (LinkedIn's
            // safety/go -> reddit). The parent shows the redirect target
            // until the next navigation; the nested webview still opens.
            final decision = handled.decision;
            if (decision != null &&
                !dispatch(decision, url: url, hadGesture: handled.hadGesture,
                    via: 'onUrlChanged')) {
              return;
            }
            final currentNotifyUrl = urlChangedState.currentUrl;
            // Nothing moved since this URL was saved (a page restating it per keystroke).
            if (decision == null && currentUrl == currentNotifyUrl &&
                currentNotifyUrl == lastSavedUrl) {
              return;
            }
            currentUrl = currentNotifyUrl;
            stateSetterF?.call();
            // Skip the title + theme IPCs when the URL didn't actually
            // advance — this is the duplicate event from the other of
            // `onLoadStop` / `onUpdateVisitedHistory` firing for the
            // same URL we just processed. Halves the chromium IPC
            // traffic per real navigation, removing one race window
            // for the `partition_alloc_support.cc:770` dangling-raw_ptr
            // SIGTRAP that can fire when an `evaluateJavascript`
            // continuation lands on a frame chromium has torn down.
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
              unawaited(controller?.setThemePreference(effectiveTheme));
            }
            await hooks.save();
            lastSavedUrl = currentNotifyUrl;
          },
          onCookiesChanged: (newCookies) async {
            // Remove blocked cookies from the webview cookie jar. The mirror
            // and the block list are those of the site the slot runs as.
            if (id.blockedCookies.isNotEmpty) {
              await hooks.removeBlockedCookies(
                newCookies
                    .where((c) => id.isCookieBlocked(c.name, domain: c.domain))
                    .toList(),
                controller: controller,
                url: Uri.parse(currentUrl.isNotEmpty ? currentUrl : id.initUrl),
              );
              id.cookies = newCookies
                  .where((c) => !id.isCookieBlocked(c.name, domain: c.domain))
                  .toList();
            } else {
              id.cookies = newCookies;
            }
            await hooks.save();
          },
          onFindResult: (activeMatch, {required totalMatches}) {
            findMatches.activeMatchOrdinal = activeMatch;
            findMatches.numberOfMatches = totalMatches;
            if (stateSetterF != null) {
              stateSetterF!();
            }
          },
          cacheFirst: cacheFirst,
          initialHtml: initialHtml,
          onRendererGone: handleRendererGone,
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
                .offer(iconSiteUrl, icon: icon, persist: !id.effectiveIncognito)),
          ),
          siteSearch: WebSearchEngine.discovers(
                  initUrl: id.initUrl, searchAddress: id.searchAddress)
              ? SiteSearchTarget(
                  siteUrl: id.initUrl,
                  onSearch: (found) {
                    if (!id.offerDiscoveredSearch(found)) return;
                    stateSetterF?.call();
                    unawaited(hooks.save());
                  },
                )
              : null,
          onConsoleMessage: (message, {required level}) {
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
          unawaited(setController());
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
          final pending = tabBinding.take(
            tab: builtTab,
            commit: const Commit.environment(Environment.frame),
          );
          if (pending != null && restores) {
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
          // covers goHome, renderer-gone rebuild, and savedForRestore
          // re-creation in one place — paths activate's own nudge
          // does not reach because they don't go through it.
          onControllerReady?.call();
        },
      );
    }
    return webview;
  }

  WebViewController? getController(WebViewHostHooks hooks) {
    if (webview == null) getWebView(hooks, cacheFirst: false);
    if (controller != null) {
      unawaited(setController());
    }
    return controller;
  }

  /// Deletes every cookie this site knows of from its jar, then forgets
  /// them. Fails with [CookieJarFailure] when the jar refuses one, and the
  /// site keeps its list, since those cookies may still be there.
  Future<void> deleteCookies(Isolation isolation) async {
    final url = Uri.parse(initUrl);
    for (final Cookie cookie in cookies) {
      await isolation.deleteCookie(cookie,
          url: url, controller: controller);
    }
    cookies = [];
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
    ProcessRoute.instance.release(routeClaim.occupant);
    tabBinding.unbind(commit: const Commit.unmodeled(Unmodeled.rendererGone));
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
  Future<void> setBackgroundPlayback({required bool active}) async {
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
    await controller?.evaluateJavascript(PageJs.mediaPause.script);
  }

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

  /// Lets go of the webview, in [commit]: an unload's, the commit that takes
  /// the site off the list, or a named rebuild.
  void disposeWebView({required Commit commit}) {
    LogTag.webView.debug(
        'disposeWebView called for "$name" (siteId: $siteId)\n${StackTrace.current}',
        sensitive: true);
    webview = null;
    controller = null;
    ProcessRoute.instance.release(routeClaim.occupant);
    tabBinding.unbind(commit: commit);
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
  /// Before `controller.reload()`, drops the engine's HTTP/image cache, so
  /// the reload hits the network instead of being satisfied from disk (a
  /// stale-cached HTML response is what bit issue #290: the user pulled to
  /// refresh and saw the same page because the engine served it from
  /// cache). Online only: offline, that cache is what the site's next
  /// start renders, and no live fetch would replace it.
  Future<void> userDrivenReload() async {
    if (controller == null) return;
    if (_userReloadInFlight) return;
    _userReloadInFlight = true;
    try {
      _beginPendingLoad();
      if (ConnectivityService.instance.lastKnownOnline ?? true) {
        await clearWebViewCache();
      }
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

  /// Capture the WebView's navigation state as bytes, with the tab the
  /// webview was built for, whose history they are. Returns null
  /// when there's nothing to save (controller is null, page never
  /// navigated, or the platform refused). Pair with the matching
  /// `restoreState` on a freshly-created controller in
  /// [getWebView]'s `onControllerCreated` handler to re-hydrate
  /// the back/forward stack and (Apple only) form-field values.
  ///
  /// Live JS heap and DOM are NOT preserved.
  Future<CapturedNavState?> captureNavigationState() async {
    final ctrl = controller;
    final tab = tabBinding.built;
    if (ctrl == null || tab == null || incognito) return null;
    final state = await ctrl.saveState();
    if (state == null || state.isEmpty) return null;
    return (tab: tab, bytes: state);
  }

  /// Current memory-tier state. Drives the
  /// [SiteLifecyclePromotionEngine] cascade. Default [SiteLifecycleState.resident]
  /// — active and paused-but-loaded sites both sit at this tier
  /// (the resume/pause distinction is orthogonal to memory tier).
  /// Promoted on memory pressure events; reset to `live` on
  /// re-activation when the webview is rebuilt.
  SiteLifecycleState get lifecycleState => _lifecycleState;
  SiteLifecycleState _lifecycleState = SiteLifecycleState.resident;

  /// The model's `tier`, written only through a [Commit].
  static final tierCell = SharedAt<WebViewModel, SiteLifecycleState>(
    ModelVar.tier,
    read: (m) => m._lifecycleState,
    write: (m, {required to}) => m._lifecycleState = to,
  );

  /// The tab the webview was built for and the back stack queued for the
  /// next build. The activation and the tab switch queue the bytes before the
  /// rebuild, so the repaint and `restoreState` land in one render cycle;
  /// [getWebView]'s `onControllerCreated` takes them.
  final WebViewTabBinding tabBinding = WebViewTabBinding();

  /// Opaque per-site container key for archive-tier sites (ARCH-007).
  /// Format mirrors [siteId] (radix-36-dash-radix-36) so a listing of the
  /// on-disk container directory shows uniform-looking names; the value
  /// itself is HMAC-derived from the archive key and the original siteId.
  /// Null for app-tier sites, which keep their container under [siteId].
  ContainerKey? archiveContainerKey;

  /// The container this site's data lives in under containers.
  ContainerKey get containerKey =>
      archiveContainerKey ?? ContainerKey.ofSite(siteId);

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
    for (final cookie in pending) {
      if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
      final dom = cookie.domain ?? '';
      final cleanDomain = dom.startsWith('.') ? dom.substring(1) : dom;
      if (cleanDomain.isEmpty) continue;
      final path = cookie.path ?? '/';
      // The plugin asserts both are non-empty.
      if (path.isEmpty) continue;
      try {
        await cookieChannel((plugin) => plugin.setCookie(
              url: inapp.WebUri('https://$cleanDomain$path'),
              name: cookie.name,
              value: cookie.value.toString(),
              domain: cookie.domain,
              path: path,
              expiresDate: cookie.expiresDate,
              isSecure: cookie.isSecure,
              isHttpOnly: cookie.isHttpOnly,
              webViewController: ctrl.nativeController,
            ));
      } on CookieJarFailure {
        // Best effort. A cookie that fails to insert (malformed
        // attributes from a legacy import, expired, etc.) is simply
        // dropped from the runtime jar; archive state still has it for
        // future round-trips.
      }
    }
  }

  String getDisplayName() {
    return name;
  }

  /// The proxy password is never serialised — same contract as
  /// `isSecure=true` cookies, which are also stripped from exports. See
  /// `openspec/specs/proxy-password-secure-storage/spec.md` (PWD-005).
  Map<String, dynamic> toJson() => toJsonMap();

  /// What an archive seals for this site (ARCH-012).
  Map<String, dynamic> toArchiveJson() => toArchiveJsonMap();

  /// Only `initUrl` is required: without one this throws a
  /// [FormatException]. Every other field of the wrong type reads as absent:
  /// the startup loader drops a site whose JSON throws and the next save
  /// deletes it, so one odd value (a hand-edited backup, a partial QR
  /// payload, a field a later build retyped) must not cost the whole site.
  factory WebViewModel.fromJson(
    Map<String, dynamic> json, {
    required Function? stateSetterF,
    bool isArchiveTier = false,
  }) =>
      webViewModelFromJson(json,
          stateSetterF: stateSetterF, isArchiveTier: isArchiveTier);
}
