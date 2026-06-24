import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp
    show CookieManager, PullToRefreshController, PullToRefreshSettings, SslCertificate, WebUri;
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/link_routing_service.dart' show LinkRoutingService;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/site_lifecycle_promotion_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/widgets/external_url_prompt.dart' show launchUrlInSystemBrowser;

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
  return '${now.toRadixString(36)}-${random.toRadixString(36)}';
}

/// Generates a fresh per-site fingerprint reset nonce. Uses [Random.secure]
/// so a site can't predict the post-reset fingerprint.
String generateFingerprintResetNonce() {
  final rng = Random.secure();
  final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

/// Common multi-part TLDs (country-code second-level domains)
/// These need special handling because the TLD is effectively two parts (e.g., .co.uk)
const Set<String> _multiPartTlds = {
  'co.uk', 'org.uk', 'me.uk', 'ac.uk', 'gov.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'net.nz', 'org.nz', 'govt.nz',
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
  'com.br', 'net.br', 'org.br', 'gov.br',
  'co.in', 'net.in', 'org.in', 'gov.in',
  'com.mx', 'org.mx', 'gob.mx',
  'co.za', 'org.za', 'gov.za',
  'com.sg', 'org.sg', 'gov.sg', 'edu.sg',
  'co.kr', 'or.kr', 'go.kr',
  'com.cn', 'net.cn', 'org.cn', 'gov.cn',
  'com.tw', 'org.tw', 'gov.tw',
  'com.hk', 'org.hk', 'gov.hk',
  'co.id', 'or.id', 'go.id',
  'com.ph', 'org.ph', 'gov.ph',
  'co.th', 'or.th', 'go.th',
  'com.vn', 'gov.vn',
  'com.my', 'org.my', 'gov.my',
  'co.il', 'org.il', 'gov.il',
  'com.tr', 'org.tr', 'gov.tr',
  'com.pl', 'org.pl', 'gov.pl',
  'co.de', 'com.de',
  'com.fr', 'org.fr', 'gouv.fr',
  'co.it', 'org.it', 'gov.it',
  'co.es', 'org.es', 'gob.es',
  'co.nl', 'org.nl',
  'com.ar', 'org.ar', 'gov.ar',
  'com.ru', 'org.ru', 'gov.ru',
};

/// Checks if a string is an IPv4 address.
bool _isIPv4Address(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final num = int.tryParse(part);
    if (num == null || num < 0 || num > 255) return false;
  }
  return true;
}

/// Checks if a string is an IPv6 address (with or without brackets).
bool _isIPv6Address(String host) {
  // Remove brackets if present (e.g., [::1] -> ::1)
  final cleaned = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  // Simple check: contains colons and valid hex characters
  if (!cleaned.contains(':')) return false;
  final validChars = RegExp(r'^[0-9a-fA-F:]+$');
  return validChars.hasMatch(cleaned);
}

/// Extracts the second-level domain (SLD + TLD) from a URL.
/// Used for cookie isolation - all subdomains of the same second-level domain
/// will have their webviews mutually excluded.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// IP addresses are returned as-is (they don't have subdomains).
/// Example: 'mail.google.com' -> 'google.com'
/// Example: 'api.github.com' -> 'github.com'
/// Example: 'www.google.co.uk' -> 'google.co.uk'
/// Example: '192.168.1.1' -> '192.168.1.1'
/// Example: '[::1]' -> '[::1]'
String getBaseDomain(String url) {
  final host = extractDomain(url);

  // IP addresses should be returned as-is - they're already unique identifiers
  if (_isIPv4Address(host) || _isIPv6Address(host)) {
    return host;
  }

  final parts = host.split('.');

  if (parts.length >= 3) {
    // Check if the last two parts form a multi-part TLD
    final possibleTld = '${parts[parts.length - 2]}.${parts.last}';
    if (_multiPartTlds.contains(possibleTld)) {
      // Return third-to-last part + multi-part TLD (e.g., google.co.uk)
      return '${parts[parts.length - 3]}.$possibleTld';
    }
  }

  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}.${parts.last}';
  }
  return host;
}

/// Domain aliases for treating different domains as equivalent for navigation.
/// Key is the alias domain, value is the canonical domain.
/// Used ONLY for nested webview URL blocking (not cookie isolation).
/// All Google properties (gmail.com, regional domains, etc.) are treated as google.com.
const Map<String, String> _domainAliases = {
  'gmail.com': 'google.com',
  // YouTube is part of Google's SSO family — `accounts.youtube.com/SetSID`
  // is a mandatory hop when signing into play.google.com, gmail, etc.,
  // since Google syncs session cookies into the YouTube jar. Without this
  // alias, the nested-webview guard treats the SetSID redirect as a
  // cross-domain navigation, opens it in a nested browser, and the main
  // webview never receives the redirect-back — the user gets stuck
  // looking "signed out" despite completing the SSO flow.
  'youtube.com': 'google.com',
  'youtu.be': 'google.com',
  'youtube-nocookie.com': 'google.com',
  // Discord
  'discordapp.com': 'discord.com',
  'discord.gg': 'discord.com',
  // Hugging Face
  'hf.co': 'huggingface.co',
  // Anthropic / Claude
  'claude.ai': 'anthropic.com',
  // OpenAI / ChatGPT
  'chatgpt.com': 'openai.com',
  // Regional Google domains
  'google.co.uk': 'google.com',
  'google.com.au': 'google.com',
  'google.co.jp': 'google.com',
  'google.co.in': 'google.com',
  'google.de': 'google.com',
  'google.fr': 'google.com',
  'google.es': 'google.com',
  'google.it': 'google.com',
  'google.nl': 'google.com',
  'google.pl': 'google.com',
  'google.ru': 'google.com',
  'google.com.br': 'google.com',
  'google.com.mx': 'google.com',
  'google.ca': 'google.com',
  'google.co.kr': 'google.com',
  'google.com.tw': 'google.com',
  'google.com.hk': 'google.com',
  'google.co.id': 'google.com',
  'google.co.th': 'google.com',
  'google.com.vn': 'google.com',
  'google.com.ph': 'google.com',
  'google.com.my': 'google.com',
  'google.com.sg': 'google.com',
  'google.co.nz': 'google.com',
  'google.co.za': 'google.com',
  'google.com.ar': 'google.com',
  'google.cl': 'google.com',
  'google.com.co': 'google.com',
  'google.com.tr': 'google.com',
  'google.co.il': 'google.com',
  'google.ae': 'google.com',
  'google.com.sa': 'google.com',
  'google.com.eg': 'google.com',
  'google.com.pk': 'google.com',
  'google.com.ng': 'google.com',
  'google.be': 'google.com',
  'google.at': 'google.com',
  'google.ch': 'google.com',
  'google.se': 'google.com',
  'google.no': 'google.com',
  'google.dk': 'google.com',
  'google.fi': 'google.com',
  'google.ie': 'google.com',
  'google.pt': 'google.com',
  'google.cz': 'google.com',
  'google.ro': 'google.com',
  'google.hu': 'google.com',
  'google.gr': 'google.com',
};

/// Normalizes a domain by applying aliases and extracting second-level domain.
/// Used for nested webview URL blocking - determines if navigation stays in same webview.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// Example: 'mail.google.com' -> 'google.com' (second-level)
/// Example: 'gmail.com' -> 'google.com' (alias)
/// Example: 'www.google.co.uk' -> 'google.com' (second-level extracted, then aliased)
String getNormalizedDomain(String url) {
  final host = extractDomain(url);

  // Check if the full host has an alias
  if (_domainAliases.containsKey(host)) {
    return _domainAliases[host]!;
  }

  // Extract base domain
  final secondLevel = getBaseDomain(url);

  // Check if the second-level domain has an alias
  if (_domainAliases.containsKey(secondLevel)) {
    return _domainAliases[secondLevel]!;
  }

  return secondLevel;
}

/// A cookie blocked by name + domain, per-site.
/// When a cookie matches, it is deleted from the webview after each page load
/// and skipped during cookie restore.
class BlockedCookie {
  final String name;
  final String domain;

  const BlockedCookie({required this.name, required this.domain});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockedCookie && name == other.name && domain == other.domain;

  @override
  int get hashCode => Object.hash(name, domain);

  Map<String, dynamic> toJson() => {'name': name, 'domain': domain};

  factory BlockedCookie.fromJson(Map<String, dynamic> json) =>
      BlockedCookie(name: json['name'] as String, domain: json['domain'] as String);
}

/// Interpret a renderer-health probe result. The probe reads
/// `document.body.offsetHeight`: a live renderer returns a number — `0`
/// (about:blank), `-1` (document/body not built yet, still loading), or a
/// positive height. A dead renderer (iOS content-process jettisoned,
/// Android renderer killed) makes `evaluateJavascript` throw, surfaced as a
/// `null` result by [WebViewController.evaluateJavascriptReturning]. Only
/// `null` means gone; every numeric value is alive.
bool rendererProbeIndicatesGone(Object? probeResult) => probeResult == null;

class WebViewModel {
  final String siteId; // Unique ID for per-site cookie isolation
  String initUrl; // Made non-final to allow URL editing
  String currentUrl;
  String name; // Custom name for the site
  String? pageTitle; // Current page title from webview
  List<Cookie> cookies;
  Widget? webview;
  WebViewController? controller;
  UserProxySettings proxySettings;
  bool javascriptEnabled;
  String userAgent;
  bool thirdPartyCookiesEnabled;
  bool incognito; // Private browsing mode - no cookies/cache persist
  /// When true, the site's currentUrl/pageTitle are not persisted: every
  /// app restart and every Android home-shortcut tap returns the site to
  /// its `initUrl`. Cookies / localStorage / IDB ARE preserved (the user
  /// keeps their login session); only the navigation URL resets. Implied
  /// by [incognito], which adds the cookie/storage wipe on top.
  bool alwaysOpenHome;
  String? language; // Language code (e.g., 'en', 'es'), null = system default
  /// Browser-style page zoom for this site, as a percent (100 = unscaled).
  /// Scales the whole page (text and images) via CSS `zoom`, independent of
  /// the OS accessibility font scale that [WebViewController.setTextZoom]
  /// tracks. Clamped to [kMinZoomPercent]..[kMaxZoomPercent].
  int zoomPercent;
  bool clearUrlEnabled; // Strip tracking parameters from URLs via ClearURLs
  bool dnsBlockEnabled; // Block navigation to domains on Hagezi DNS blocklist
  bool contentBlockEnabled; // Block ads/trackers via ABP filter list rules
  /// Umbrella per-site Enhanced Tracking Protection: when true, applies
  /// the anti-fingerprinting JS shim (Canvas/WebGL/audio/fonts/screen/
  /// hardware/timing) AND forces clearUrlEnabled, dnsBlockEnabled, and
  /// contentBlockEnabled to behave as on regardless of their own value.
  /// When false, the three sub-toggles act independently as before.
  bool trackingProtectionEnabled;
  bool localCdnEnabled; // Serve CDN resources from local cache for privacy
  bool blockAutoRedirects; // Block script-initiated cross-domain navigations
  /// When true, a cross-domain link that is not covered by this site's
  /// domain claims opens in the system's default browser instead of a
  /// nested in-app webview (discussion #438). Links to claimed domains
  /// still open in-app. Default false: the legacy nested-webview routing.
  bool externalLinksInBrowser;
  bool fullscreenMode; // Auto-enter fullscreen when this site is selected
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
  /// Remembered per-site decision for protected (DRM/Widevine EME) content,
  /// e.g. the Spotify web player. null = not yet decided (the webview shows
  /// an Allow/Block popup on the first `PROTECTED_MEDIA_ID` permission
  /// request); true = grant silently; false = deny silently. Granting lets
  /// the origin provision a Widevine device identifier, so the default is
  /// "ask" rather than always-on. Android-only: WKWebView (iOS/macOS) has no
  /// EME/Widevine support and never issues this request.
  bool? protectedContentAllowed;
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
  /// [Date.prototype.getTimezoneOffset]. Null leaves the real zone.
  String? spoofTimezone;
  /// When true, the effective spoof timezone is derived from
  /// (spoofLatitude, spoofLongitude) at shim-build time via
  /// [TimezoneLocationService]. [spoofTimezone] is ignored in that case
  /// (it stays null; the field is mutually exclusive). Resolution happens
  /// in `webview.dart`, not here, because it depends on a separately-
  /// loadable polygon dataset that may not be present.
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

  /// User-defined domain-claim list used by `LinkRoutingService` to route
  /// inbound share/open-intent URLs to a site (LIR-001..LIR-010). When
  /// null, the resolver behaves as if the site claimed
  /// `[baseDomain(getBaseDomain(initUrl))]` (the legacy synthesized
  /// default). Serialised only when non-null so on-disk JSON for users who
  /// never touch the feature stays byte-identical.
  List<DomainClaim>? domainClaims;

  /// View used by the resolver — always non-empty: returns the explicit
  /// `domainClaims` if the user has set them, otherwise the synthesized
  /// `[baseDomain(getBaseDomain(initUrl))]` per LIR-001.
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

  /// Whether the webview is currently mid-navigation. Set true on
  /// `onLoadStart`, false on `onLoadStop`. Driven by the
  /// `WebViewConfig.onLoadingChanged` callback wired in [getWebView].
  /// Consumed by the URL-bar action button to swap Refresh ↔ Stop
  /// while a load is in flight.
  bool isLoading = false;

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
      isArchiveTier ? false : notificationsEnabled;

  /// Effective LocalCDN cache write enable. Archive-tier sites never
  /// write the per-site CDN cache to disk regardless of stored value.
  bool get effectiveLocalCdnEnabled =>
      isArchiveTier ? false : localCdnEnabled;

  /// Effective HTML-cache enable. Archive-tier sites never write the
  /// encrypted-at-rest HTML cache (the cache file path is keyed by
  /// `siteId`, so its existence would correlate to specific archive
  /// sites on disk inspection — ARCH-006).
  bool get effectiveHtmlCachingEnabled =>
      isArchiveTier ? false : htmlCachingEnabled;

  /// Whether this site may persist/restore webview navigation state
  /// (`controller.saveState()` bytes) to the device-key on-disk store.
  /// Single source of truth for the capture, debounce, and cold-start
  /// restore gates. False for:
  /// - **archive-tier** (ARCH-006): the bytes would land in a per-`siteId`
  ///   file whose existence correlates to a specific archive site on disk;
  ///   archive state lives only in the slot-pool ciphertext, never a file.
  /// - **incognito**: navigation state is meant to be ephemeral.
  bool get persistsNavState => !isArchiveTier && !incognito;

  /// Effective protected-content (Widevine/EME) decision. Archive-tier
  /// sites never grant DRM regardless of stored value: a grant provisions
  /// a per-container Widevine device identifier on disk and the prompt is
  /// OS-level UI, both of which ARCH-006 forbids for archive sites. They
  /// deny without prompting (false, never null = never "ask").
  bool? get effectiveProtectedContentAllowed =>
      isArchiveTier ? false : protectedContentAllowed;

  /// Effective "open external links in the system browser" setting.
  /// Archive-tier sites never hand a URL to another app: launching the
  /// system browser is OS-level UI that crosses the archive's isolation
  /// boundary (ARCH-006), so archive sites keep links in-app regardless
  /// of the stored value.
  bool get effectiveExternalLinksInBrowser =>
      isArchiveTier ? false : externalLinksInBrowser;

  final List<ConsoleLogEntry> consoleLogs = [];
  static const _maxConsoleLogs = 500;
  VoidCallback? onConsoleLogChanged;

  String? defaultUserAgent;
  /// In-flight protected-content decision. A page can fire several
  /// `PROTECTED_MEDIA_ID` requests in a burst while EME initializes; this
  /// coalesces them onto a single Allow/Block popup instead of stacking
  /// dialogs. Cleared once [protectedContentAllowed] is recorded.
  Future<bool>? _protectedMediaDecisionInFlight;
  Function? stateSetterF;
  /// Host hook fired once each time a fresh native controller attaches for
  /// this model (cold start, `_goHome` recreate, renderer-gone recovery,
  /// savedForRestore re-creation). The host uses it to recomposite the
  /// Android hybrid-composition surface, which can re-attach blank-white
  /// when a new platform view mounts. Re-activation of an already-loaded
  /// webview does NOT recreate the controller, so it does not fire here —
  /// that path is nudged explicitly by `_setCurrentIndex`.
  Function? onControllerReady;
  FindMatchesResult findMatches = FindMatchesResult();
  WebViewTheme _currentTheme = WebViewTheme.light;

  /// The theme most recently applied to this webview via [setTheme]. Used
  /// by callers (e.g. HTML cache prelude) that need to render a frame that
  /// matches the current theme before scripts and stylesheets load.
  WebViewTheme get currentTheme => _currentTheme;

  WebViewModel({
    String? siteId,
    required this.initUrl,
    String? currentUrl,
    String? name,
    this.cookies = const [],
    UserProxySettings? proxySettings,
    this.javascriptEnabled = true,
    this.userAgent = '',
    this.thirdPartyCookiesEnabled = false,
    this.incognito = false,
    this.alwaysOpenHome = false,
    this.language,
    this.zoomPercent = kDefaultZoomPercent,
    this.clearUrlEnabled = true,
    this.dnsBlockEnabled = true,
    this.contentBlockEnabled = true,
    this.trackingProtectionEnabled = true,
    this.localCdnEnabled = true,
    this.blockAutoRedirects = true,
    this.externalLinksInBrowser = false,
    this.fullscreenMode = false,
    this.htmlCachingEnabled = false,
    this.notificationsEnabled = false,
    this.protectedContentAllowed,
    List<UserScriptConfig>? userScripts,
    Set<String>? enabledGlobalScriptIds,
    Set<BlockedCookie>? blockedCookies,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.liveLocationGranularity = LocationGranularity.gps,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.letterboxEnabled = false,
    this.spoofWindowWidth,
    this.spoofWindowHeight,
    this.fingerprintResetNonce,
    this.domainClaims,
    this.stateSetterF,
    this.isArchiveTier = false,
  })  : userScripts = userScripts ?? [],
        enabledGlobalScriptIds = enabledGlobalScriptIds ?? {},
        blockedCookies = blockedCookies ?? {},
        siteId = siteId ?? _generateSiteId(),
        currentUrl = currentUrl ?? initUrl,
        name = name ?? extractDomain(initUrl),
        proxySettings = proxySettings ?? UserProxySettings(type: ProxyType.DEFAULT);

  /// Reroll the per-site anti-fingerprinting seed. Called when the user
  /// clears this site's data so the post-wipe page sees a fresh fingerprint
  /// (window size, canvas, WebGL, …) and can't re-identify the user (ETP-022).
  void rerollFingerprint() {
    fingerprintResetNonce = generateFingerprintResetNonce();
  }

  /// Check if a cookie is blocked by name + domain for this site.
  bool isCookieBlocked(String name, String? domain) {
    if (blockedCookies.isEmpty) return false;
    return blockedCookies.any((b) =>
        b.name == name &&
        (domain != null && (b.domain == domain ||
            domain.endsWith('.${b.domain}') ||
            b.domain.endsWith('.$domain'))));
  }

  void removeThirdPartyCookies(WebViewController controller) async {
    String script = '''
      (function() {
        function getDomain(hostname) {
          var parts = hostname.split('.');
          if (parts.length <= 2) {
            return hostname;
          }
          return parts.slice(parts.length - 2).join('.');
        }

        var currentDomain = getDomain(location.hostname);

        var cookies = document.cookie.split("; ");
        for (var i = 0; i < cookies.length; i++) {
          var cookie = cookies[i];
          var domain = cookie.match(/domain=[^;]+/);
          if (domain) {
            var domainValue = domain[0].split("=")[1];
            if (getDomain(domainValue) !== currentDomain) {
              var cookieName = cookie.split("=")[0];
              document.cookie = cookieName + "=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/; domain=" + domainValue;
            }
          }
        }
      })();
    ''';

    await controller.evaluateJavascript(script);
  }

  Future<void> setController() async {
    if (controller == null) {
      return;
    }
    // Apply proxy settings first (before loading any URLs)
    await _applyProxySettings();

    // The controller can be disposed across these awaits — a memory-pressure
    // eviction, a site delete while `onControllerCreated` is still settling, or
    // widget teardown. `disposeWebView()` nulls the ref, but a widget-level
    // dispose leaves a non-null ref to a now-dead native controller (asserts
    // "used after disposed"). Capture the controller and swallow that error:
    // there's nothing to configure on a dead one.
    final c = controller;
    if (c == null) return;
    try {
      await c.setOptions(
        javascriptEnabled: javascriptEnabled,
        userAgent: userAgent.isNotEmpty ? userAgent : null,
        thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
        incognito: incognito,
      );
      // Apply current theme preference
      await c.setThemePreference(_currentTheme);
      // Don't call loadUrl here - it's already initialized with the URL
      if (defaultUserAgent == null) {
        defaultUserAgent = await c.getDefaultUserAgent();
      }
    } catch (e) {
      // Controller disposed mid-setup, or webview not fully initialized
      // (common in tests). Nothing left to configure.
      defaultUserAgent ??= '';
      LogService.instance.log(
        'WebView',
        'setController skipped configuring a disposed/unavailable '
            'controller for "$name": $e',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
    }
  }

  /// Apply proxy settings to the webview.
  ///
  /// Android: routes through the global `inapp.ProxyController`. Takes
  /// effect on next request without reload.
  ///
  /// iOS / macOS: no-op — the per-site proxy is bound to the per-site
  /// `WKWebsiteDataStore` at WebView construction (via
  /// `inapp.InAppWebViewSettings.proxySettings`). To pick up a runtime
  /// change, the WebView must be rebuilt; see [updateProxySettings].
  Future<void> _applyProxySettings() async {
    final proxyManager = ProxyManager();
    try {
      await proxyManager.setProxySettings(proxySettings);
    } catch (e) {
      LogService.instance.log(
        'WebView',
        'Failed to apply proxy settings: $e',
        level: LogLevel.error,
        // Exception text can include proxy host / username / scheme,
        // which are per-site identifiers for any site with a custom
        // proxy (including archive-tier sites). Keep in the memory ring.
        sensitivity: LogSensitivity.sensitive,
      );
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
    if (controller != null && webview != null) {
      try {
        await controller!.setThemePreference(theme);
      } catch (_) {
        // Controller may have been disposed during domain conflict unload
      }
    }
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
    if (Platform.isIOS || Platform.isMacOS) {
      disposeWebView();
      return;
    }
    await _applyProxySettings();
  }

  Widget getWebView(
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required bool localCdnEnabled, required bool trackingProtectionEnabled, bool letterboxEnabled, int? spoofWindowWidth, int? spoofWindowHeight, String? fingerprintResetNonce, required String? language, required int zoomPercent, LocationMode locationMode, double? spoofLatitude, double? spoofLongitude, double spoofAccuracy, String? spoofTimezone, bool spoofTimezoneFromLocation, LocationGranularity liveLocationGranularity, WebRtcPolicy webRtcPolicy, required List<UserScriptConfig> userScripts, UserProxySettings? proxySettings, bool notificationsEnabled, bool externalLinksInBrowser}) launchUrlFunc,
    CookieManager cookieManager,
    ContainerCookieManager? containerCookieManager,
    Function saveFunc, {
    Future<void> Function(int windowId, String url)? onWindowRequested,
    String? language,
    Function(String url, String html)? onHtmlLoaded,
    bool Function()? shouldFetchHtml,
    String? initialHtml,
    bool Function()? isActive,
    Future<bool> Function(String url)? onConfirmScriptFetch,
    Future<bool> Function(
      String host,
      int port,
      inapp.SslCertificate? certificate,
    )? onUntrustedCertificate,
    Future<void> Function(String url, ExternalUrlInfo info)? onExternalSchemeUrl,
    Future<bool> Function(String origin)? onProtectedMediaRequest,
    List<UserScriptConfig> globalUserScripts = const [],
  }) {
    if (webview == null) {
      // Use this.language directly to ensure we get the current value from WebViewModel
      final effectiveLanguage = this.language;
      LogService.instance.log(
        'WebView',
        'Creating webview for "$name" (siteId: $siteId, initUrl: $initUrl)',
        sensitivity: LogSensitivity.sensitive,
      );
      LogService.instance.log(
        'WebView',
        'Language: $effectiveLanguage (param: $language)',
      );
      LogService.instance.log(
        'WebView',
        'Using cached HTML: ${initialHtml != null} (${initialHtml?.length ?? 0} bytes)',
        sensitivity: LogSensitivity.sensitive,
      );
      final bool isMobile = Platform.isIOS || Platform.isAndroid;
      final pullToRefreshController = isMobile ? inapp.PullToRefreshController(
        settings: inapp.PullToRefreshSettings(enabled: true),
        onRefresh: () async {
          await userDrivenReload();
        },
      ) : null;
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
      // True when `u` is covered by one of this site's domain claims. The
      // externalLinksInBrowser path keeps claimed cross-domain links in a
      // nested webview and only hands unclaimed ones to the system browser.
      bool matchesSiteClaim(String u) {
        final uri = Uri.tryParse(u);
        return uri != null &&
            LinkRoutingService.urlMatchesAnyClaim(uri, effectiveDomainClaims);
      }
      // Android restore ordering: when nav-state bytes are queued for this
      // build, the webview must apply restoreState to a pristine back/forward
      // list. Suppress the initial load on Android and materialize the
      // restored entry from onControllerCreated; iOS/macOS keep the
      // initialUrlRequest load and replace state in place via interactionState.
      final bool deferRestoreLoad = deferInitialLoadForRestore(
        hasPendingRestoreState: _pendingRestoreState != null,
        isAndroid: Platform.isAndroid,
        isFileImport: currentUrl.startsWith('file://'),
      );
      webview = WebViewFactory.createWebView(
        config: WebViewConfig(
          key: UniqueKey(), // Force new widget state when recreating
          siteId: siteId,
          archiveContainerId: archiveContainerId,
          initialUrl: currentUrl,
          javascriptEnabled: javascriptEnabled,
          userAgent: userAgent.isNotEmpty ? userAgent : null,
          thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
          incognito: incognito,
          // Root site webview sits at the MaterialApp root route: on iOS/macOS
          // there is no Flutter route-pop edge-swipe here, so opt into
          // WKWebView's native back/forward swipe. Nested screens don't (NAV-008).
          backForwardGestures: true,
          deferInitialLoad: deferRestoreLoad,
          language: effectiveLanguage, // Use WebViewModel's language, not parameter
          zoomPercent: zoomPercent,
          // Umbrella `trackingProtectionEnabled`: when on, the four
          // tracker-protection subordinates behave as ON regardless of
          // their per-site stored value. The stored values are still
          // respected when the umbrella is off so users can opt out of
          // individual paths under a custom posture.
          clearUrlEnabled: clearUrlEnabled || trackingProtectionEnabled,
          dnsBlockEnabled: dnsBlockEnabled || trackingProtectionEnabled,
          contentBlockEnabled: contentBlockEnabled || trackingProtectionEnabled,
          localCdnEnabled: localCdnEnabled || trackingProtectionEnabled,
          trackingProtectionEnabled: trackingProtectionEnabled,
          letterboxEnabled: letterboxEnabled,
          spoofWindowWidth: spoofWindowWidth,
          spoofWindowHeight: spoofWindowHeight,
          fingerprintResetNonce: fingerprintResetNonce,
          // The effective timezone is resolved from the spoofed coords and
          // persisted into `spoofTimezone` at settings-save time (Tracking
          // Protection's force-from-location is applied there too), so the
          // runtime just passes the stored value through — the polygon
          // dataset never loads on this path.
          locationMode: locationMode,
          spoofLatitude: spoofLatitude,
          spoofLongitude: spoofLongitude,
          spoofAccuracy: spoofAccuracy,
          spoofTimezone: spoofTimezone,
          spoofTimezoneFromLocation: spoofTimezoneFromLocation,
          liveLocationGranularity: liveLocationGranularity,
          webRtcPolicy: webRtcPolicy,
          // Per-site proxy. Honored at WebView construction on iOS 17+ /
          // macOS 14+ via the patched `preWKWebViewConfiguration` (see
          // PROXY-002 / PROXY-008). Android ignores this and routes
          // through the global `ProxyController` in `_applyProxySettings`.
          proxySettings: proxySettings,
          notificationsEnabled: notificationsEnabled,
          userScripts: combineUserScripts(globalUserScripts),
          onConfirmScriptFetch: onConfirmScriptFetch,
          onUntrustedCertificate: onUntrustedCertificate,
          onExternalSchemeUrl: onExternalSchemeUrl,
          onProtectedMediaRequest: onProtectedMediaRequest == null
              ? null
              : (origin) async {
                  // Archive-tier sites deny without prompting; otherwise a
                  // previously remembered Allow/Block decision short-circuits
                  // the popup.
                  final remembered = effectiveProtectedContentAllowed;
                  if (remembered != null) return remembered;
                  // Coalesce a burst of requests onto one popup.
                  _protectedMediaDecisionInFlight ??= () async {
                    final granted = await onProtectedMediaRequest(origin);
                    protectedContentAllowed = granted;
                    await saveFunc();
                    return granted;
                  }();
                  try {
                    return await _protectedMediaDecisionInFlight!;
                  } finally {
                    _protectedMediaDecisionInFlight = null;
                  }
                },
          pullToRefreshController: pullToRefreshController,
          onWindowRequested: onWindowRequested,
          shouldOverrideUrlLoading: (url, hasGesture) {
            LogService.instance.log(
              'WebView',
              'shouldOverrideUrlLoading: site="$name" (siteId: $siteId) initUrl=$initUrl request=$url hasGesture=$hasGesture',
              sensitivity: LogSensitivity.sensitive,
            );
            final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
              targetUrl: url,
              initUrl: initUrl,
              hasGesture: hasGesture,
              blockAutoRedirects: blockAutoRedirects,
              isSiteActive: isActive?.call() ?? true,
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: DateTime.now(),
              externalLinksInBrowser: effectiveExternalLinksInBrowser,
              matchesSiteClaim: matchesSiteClaim,
            );
            switch (result.gestureUpdate) {
              case GestureStateUpdate.record:
                lastSameDomainGestureTime = DateTime.now();
                break;
              case GestureStateUpdate.consume:
                lastSameDomainGestureTime = null;
                break;
              case null:
                break;
            }
            switch (result.decision) {
              case NavigationDecision.allow:
                LogService.instance.log(
                  'WebView',
                  '  -> ALLOW',
                  sensitivity: LogSensitivity.sensitive,
                );
                return true;
              case NavigationDecision.blockSilent:
                LogService.instance.log(
                  'WebView',
                  '  -> CANCEL (auto-redirect blocked, no user gesture)',
                  sensitivity: LogSensitivity.sensitive,
                );
                return false;
              case NavigationDecision.blockSuppressed:
                LogService.instance.log(
                  'WebView',
                  '  -> CANCEL (background site, suppressing nested webview)',
                  sensitivity: LogSensitivity.sensitive,
                );
                return false;
              case NavigationDecision.blockOpenNested:
                LogService.instance.log(
                  'WebView',
                  '  -> CANCEL (opening nested webview)',
                  sensitivity: LogSensitivity.sensitive,
                );
                launchUrlFunc(url, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, localCdnEnabled: localCdnEnabled, trackingProtectionEnabled: trackingProtectionEnabled, letterboxEnabled: letterboxEnabled, spoofWindowWidth: spoofWindowWidth, spoofWindowHeight: spoofWindowHeight, fingerprintResetNonce: fingerprintResetNonce, language: this.language, zoomPercent: zoomPercent, locationMode: locationMode, spoofLatitude: spoofLatitude, spoofLongitude: spoofLongitude, spoofAccuracy: spoofAccuracy, spoofTimezone: spoofTimezone, spoofTimezoneFromLocation: spoofTimezoneFromLocation, liveLocationGranularity: liveLocationGranularity, webRtcPolicy: webRtcPolicy, userScripts: combineUserScripts(globalUserScripts), proxySettings: proxySettings, notificationsEnabled: notificationsEnabled, externalLinksInBrowser: effectiveExternalLinksInBrowser);
                return false;
              case NavigationDecision.blockOpenExternal:
                LogService.instance.log(
                  'WebView',
                  '  -> CANCEL (opening system browser)',
                  sensitivity: LogSensitivity.sensitive,
                );
                launchUrlInSystemBrowser(url);
                return false;
            }
          },
          onLoadingChanged: (loading) {
            if (isLoading == loading) return;
            isLoading = loading;
            // Trigger a UI rebuild so the URL-bar action button can
            // swap between Refresh and Stop. saveFunc is intentionally
            // NOT called here — the loading bool is transient runtime
            // state, not part of the persisted site model.
            stateSetterF?.call();
          },
          onUrlChanged: (url) async {
            // Detect cross-domain redirects that bypassed shouldOverrideUrlLoading
            // (e.g., server-side 302 from search engine redirect pages like
            // DuckDuckGo's /l/?uddg=... or Google's /url?q=...).
            final initDomain = getNormalizedDomain(initUrl);
            final handled = NavigationDecisionEngine.handleOnUrlChanged(
              newUrl: url,
              initUrl: initUrl,
              blockAutoRedirects: blockAutoRedirects,
              isSiteActive: isActive?.call() ?? true,
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: DateTime.now(),
              isCaptchaChallenge: WebViewFactory.isCaptchaChallenge,
              state: urlChangedState,
              externalLinksInBrowser: effectiveExternalLinksInBrowser,
              matchesSiteClaim: matchesSiteClaim,
            );
            switch (handled.gestureUpdate) {
              case GestureStateUpdate.record:
                lastSameDomainGestureTime = DateTime.now();
                break;
              case GestureStateUpdate.consume:
                lastSameDomainGestureTime = null;
                break;
              case null:
                break;
            }
            urlChangedState = handled.state;
            // Navigate-back was previously fired here when a cross-domain
            // URL was confirmed via `controller.getUrl()`. Removed: even
            // the conservative `stopLoading()` + `Future.microtask` +
            // `loadUrl(prev)` sequence still races chromium's in-flight
            // cross-origin redirect handling on the broken Android
            // System WebView build that surfaces a dangling-raw_ptr
            // SIGTRAP at `partition_alloc_support.cc:770`. Real-device
            // logs reproduced the crash on the LinkedIn safety/go →
            // reddit redirect sequence with cached-HTML and WebGL paths
            // already mitigated; the only remaining suspect is our own
            // loadUrl-during-redirect.
            //
            // Trade-off: when a cross-domain server-side redirect bypasses
            // shouldOverrideUrlLoading, the parent webview briefly
            // displays the redirect target until the next user-initiated
            // navigation. The nested webview still opens (handled below)
            // so the user sees the destination they actually wanted.
            // That visual artifact is preferable to crashing the
            // renderer.
            if (handled.decision != null &&
                handled.decision != NavigationDecision.allow) {
              switch (handled.decision!) {
                case NavigationDecision.blockSilent:
                  LogService.instance.log(
                    'WebView',
                    'onUrlChanged: cross-domain redirect blocked: $url (expected domain: $initDomain)',
                    sensitivity: LogSensitivity.sensitive,
                  );
                  return;
                case NavigationDecision.blockSuppressed:
                  LogService.instance.log(
                    'WebView',
                    'onUrlChanged: cross-domain redirect suppressed (background site): $url',
                    sensitivity: LogSensitivity.sensitive,
                  );
                  return;
                case NavigationDecision.blockOpenNested:
                  LogService.instance.log(
                    'WebView',
                    'onUrlChanged: cross-domain redirect detected: $url (expected domain: $initDomain)',
                    sensitivity: LogSensitivity.sensitive,
                  );
                  if (handled.launchNestedUrl != null) {
                    launchUrlFunc(handled.launchNestedUrl!, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, localCdnEnabled: localCdnEnabled, trackingProtectionEnabled: trackingProtectionEnabled, letterboxEnabled: letterboxEnabled, spoofWindowWidth: spoofWindowWidth, spoofWindowHeight: spoofWindowHeight, fingerprintResetNonce: fingerprintResetNonce, language: this.language, zoomPercent: zoomPercent, locationMode: locationMode, spoofLatitude: spoofLatitude, spoofLongitude: spoofLongitude, spoofAccuracy: spoofAccuracy, spoofTimezone: spoofTimezone, spoofTimezoneFromLocation: spoofTimezoneFromLocation, liveLocationGranularity: liveLocationGranularity, webRtcPolicy: webRtcPolicy, userScripts: combineUserScripts(globalUserScripts), proxySettings: proxySettings, notificationsEnabled: notificationsEnabled, externalLinksInBrowser: effectiveExternalLinksInBrowser);
                  }
                  return;
                case NavigationDecision.blockOpenExternal:
                  LogService.instance.log(
                    'WebView',
                    'onUrlChanged: cross-domain redirect to system browser: $url (expected domain: $initDomain)',
                    sensitivity: LogSensitivity.sensitive,
                  );
                  if (handled.launchExternalUrl != null) {
                    launchUrlInSystemBrowser(handled.launchExternalUrl!);
                  }
                  return;
                case NavigationDecision.allow:
                  break;
              }
            }
            // State committed; sync currentUrl to the state's view of it.
            currentUrl = urlChangedState.currentUrl;
            // Trigger UI rebuild so URL bar updates
            if (stateSetterF != null) {
              stateSetterF!();
            }
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
              // Each await below is a yield point where disposeWebView() can
              // null `controller`, so we re-check before every native call —
              // calling into a torn-down WebView peer can trip Chromium's
              // dangling raw_ptr detector and SIGTRAP the renderer.
              try {
                if (controller == null) return;
                final title = await controller!.getTitle();
                if (controller == null) return;
                if (title != null && title.isNotEmpty) {
                  pageTitle = title;
                  // Auto-update name from page title if name is still the default domain
                  if (name == extractDomain(initUrl)) {
                    name = title;
                  }
                }
              } catch (_) {
                // Controller torn down mid-call — safe to swallow, the next
                // page load on the new controller will reapply title.
              }
              // Reapply theme after page load (some sites might override it).
              // Fire-and-forget: don't await. The await chained an
              // evaluateJavascript continuation onto our local Dart future,
              // and that continuation is the candidate that lands on a
              // dying frame when chromium tears down between our request
              // and its dispatch. The theme call doesn't gate any
              // subsequent work — saveFunc below is Dart-only.
              controller?.setThemePreference(_currentTheme).catchError((_) {});
            }
            await saveFunc();
          },
          // Route the post-load cookie read through whichever
          // manager is active for this engine. Container mode hits the
          // per-site container via the fork's `webViewController:`;
          // legacy mode hits the global jar.
          cookieManager: cookieManager,
          containerCookieManager: containerCookieManager,
          cookieSiteId: siteId,
          onCookiesChanged: (newCookies) async {
            // Remove blocked cookies from the webview cookie jar
            if (blockedCookies.isNotEmpty) {
              final blocked = newCookies.where((c) => isCookieBlocked(c.name, c.domain)).toList();
              final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : initUrl);
              for (final c in blocked) {
                if (containerCookieManager != null) {
                  await containerCookieManager.deleteCookie(
                    controller: controller,
                    siteId: siteId,
                    url: url,
                    name: c.name,
                    domain: c.domain,
                    path: c.path ?? '/',
                  );
                } else {
                  await cookieManager.deleteCookie(
                    url: url,
                    name: c.name,
                    domain: c.domain,
                    path: c.path ?? '/',
                  );
                }
              }
              cookies = newCookies.where((c) => !isCookieBlocked(c.name, c.domain)).toList();
            } else {
              cookies = newCookies;
            }
            if (!thirdPartyCookiesEnabled && controller != null) {
              removeThirdPartyCookies(controller!);
            }
            await saveFunc();
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
          LogService.instance.log(
            'WebView',
            'onControllerCreated for "$name" (siteId: $siteId)',
            sensitivity: LogSensitivity.sensitive,
          );
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
            // this — the page is already on screen.
            final materialize = deferRestoreLoad;
            final restoreUrl = currentUrl;
            unawaited(() async {
              try {
                final ok = await ctrl.restoreState(pending);
                LogService.instance.log(
                  'WebView',
                  'restoreState for "$name" (siteId: $siteId): $ok',
                  sensitivity: LogSensitivity.sensitive,
                );
                if (materialize) {
                  // ok: reload the restored top entry (keeps the back stack).
                  // !ok: nothing was restored, so just load the saved URL or
                  // the suppressed-initial-load webview would stay blank.
                  if (ok) {
                    await ctrl.reload();
                  } else {
                    await ctrl.loadUrl(restoreUrl);
                  }
                }
              } catch (_) {
                // Restore is best-effort. On Apple the page is already
                // loading from `currentUrl`; on Android the initial load was
                // suppressed, so fall back to loading it explicitly or the
                // view would stay blank.
                if (materialize) {
                  try {
                    await ctrl.loadUrl(restoreUrl);
                  } catch (_) {}
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
    return webview!;
  }

  WebViewController? getController(
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required bool localCdnEnabled, required bool trackingProtectionEnabled, bool letterboxEnabled, int? spoofWindowWidth, int? spoofWindowHeight, String? fingerprintResetNonce, required String? language, required int zoomPercent, LocationMode locationMode, double? spoofLatitude, double? spoofLongitude, double spoofAccuracy, String? spoofTimezone, bool spoofTimezoneFromLocation, LocationGranularity liveLocationGranularity, WebRtcPolicy webRtcPolicy, required List<UserScriptConfig> userScripts, UserProxySettings? proxySettings, bool notificationsEnabled, bool externalLinksInBrowser}) launchUrlFunc,
    CookieManager cookieManager,
    ContainerCookieManager? containerCookieManager,
    Function saveFunc, {
    List<UserScriptConfig> globalUserScripts = const [],
  }) {
    if (webview == null) {
      // Create webview with current language setting
      webview = getWebView(launchUrlFunc, cookieManager, containerCookieManager, saveFunc, language: language, globalUserScripts: globalUserScripts);
    }
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
    LogService.instance.log(
      'WebView',
      'Renderer gone for "$name" (siteId: $siteId, didCrash: $didCrash) — recreating',
    );
    webview = null;
    controller = null;
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
  Future<void> pauseWebView() async {
    if (controller == null) return;
    if (notificationsEnabled) return;
    try {
      await controller!.pause();
      LogService.instance.log(
        'WebView',
        'Paused webview for "$name" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Resume a previously paused webview when it becomes active again.
  Future<void> resumeWebView() async {
    if (controller == null) return;
    try {
      await controller!.resume();
      LogService.instance.log(
        'WebView',
        'Resumed webview for "$name" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (_) {
      // Controller may have been disposed
    }
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
    try {
      await c.pause();
      await c.pauseAllJsTimers();
      LogService.instance.log(
        'WebView',
        'App-lifecycle paused webview for "$name" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Inverse of [pauseForAppLifecycle].
  Future<void> resumeFromAppLifecycle() async {
    // See [pauseForAppLifecycle]: bind both calls to one local controller so a
    // concurrent dispose can't strand the process-global resumeAllJsTimers.
    final c = controller;
    if (c == null) return;
    try {
      await c.resume();
      await c.resumeAllJsTimers();
      LogService.instance.log(
        'WebView',
        'App-lifecycle resumed webview for "$name" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Dispose the webview and controller to release resources.
  /// Used when unloading a site due to domain conflict.
  void disposeWebView() {
    LogService.instance.log(
      'WebView',
      'disposeWebView called for "$name" (siteId: $siteId)\n${StackTrace.current}',
      sensitivity: LogSensitivity.sensitive,
    );
    webview = null;
    controller = null;
  }

  /// Drop the in-memory cache (decoded image cache + HTTP response
  /// cache) without disposing the webview. Tab state stays. Used by
  /// the [SiteLifecyclePromotionEngine] cacheCleared tier under OS
  /// memory pressure. Idempotent. No-op when controller is null
  /// (already disposed).
  Future<void> clearWebViewCache() async {
    if (controller == null) return;
    try {
      await controller!.clearCache();
      LogService.instance.log(
        'WebView',
        'Cleared in-memory cache for "$name" (siteId: $siteId)',
        sensitivity: LogSensitivity.sensitive,
      );
    } catch (_) {
      // Controller may have been disposed mid-call.
    }
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
    if (ConnectivityService.instance.lastKnownOnline ?? true) {
      HtmlCacheService.instance.evictInMemory(siteId);
    }
    await clearWebViewCache();
    try {
      await controller!.reload();
    } catch (_) {
      // Controller may have been disposed between the cache clear and the reload.
    }
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
    if (controller != null) {
      try {
        await controller!.stopLoading();
      } catch (_) {
        // Controller may have been disposed while the cancel was in flight.
      }
    }
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
    try {
      final state = await controller!.saveState();
      if (state == null || state.isEmpty) return null;
      return state;
    } catch (_) {
      return null;
    }
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
      if (cookie.value.isEmpty) continue;
      final dom = cookie.domain ?? '';
      final cleanDomain = dom.startsWith('.') ? dom.substring(1) : dom;
      if (cleanDomain.isEmpty) continue;
      final path = cookie.path ?? '/';
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
      } catch (_) {
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
    final dropUrl = incognito || alwaysOpenHome;
    return {
        'siteId': siteId,
        'initUrl': initUrl,
        if (!dropUrl) 'currentUrl': currentUrl,
        'name': name,
        if (!dropUrl) 'pageTitle': pageTitle,
        'cookies': incognito
            ? const <Map<String, dynamic>>[]
            : cookies.map((cookie) => cookie.toJson()).toList(),
        'proxySettings': proxySettings.toJson(),
        'javascriptEnabled': javascriptEnabled,
        'userAgent': userAgent,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'incognito': incognito,
        'alwaysOpenHome': alwaysOpenHome,
        'language': language,
        if (zoomPercent != kDefaultZoomPercent) 'zoomPercent': zoomPercent,
        'clearUrlEnabled': clearUrlEnabled,
        'dnsBlockEnabled': dnsBlockEnabled,
        'contentBlockEnabled': contentBlockEnabled,
        'trackingProtectionEnabled': trackingProtectionEnabled,
        'localCdnEnabled': localCdnEnabled,
        'blockAutoRedirects': blockAutoRedirects,
        if (externalLinksInBrowser) 'externalLinksInBrowser': true,
        'fullscreenMode': fullscreenMode,
        'htmlCachingEnabled': htmlCachingEnabled,
        'notificationsEnabled': notificationsEnabled,
        if (protectedContentAllowed != null)
          'protectedContentAllowed': protectedContentAllowed,
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
        if (domainClaims != null && domainClaims!.isNotEmpty)
          'domainClaims': domainClaims!.map((c) => c.toJson()).toList(),
      };
  }

  factory WebViewModel.fromJson(
    Map<String, dynamic> json,
    Function? stateSetterF, {
    bool isArchiveTier = false,
  }) {
    final isIncognito = json['incognito'] as bool? ?? false;
    final isAlwaysOpenHome = json['alwaysOpenHome'] as bool? ?? false;
    // Either flag drops persisted currentUrl/pageTitle on rehydrate; only
    // incognito additionally clears cookies. Defends against legacy JSON
    // written by older builds that didn't strip on toJson.
    final dropUrl = isIncognito || isAlwaysOpenHome;
    return WebViewModel(
      siteId: json['siteId'], // May be null for legacy data, will auto-generate
      initUrl: migrateLegacyFileImportUrl(json['initUrl'] as String),
      currentUrl: dropUrl || json['currentUrl'] == null
          ? null
          : migrateLegacyFileImportUrl(json['currentUrl'] as String),
      name: json['name'],
      cookies: isIncognito
          ? const <Cookie>[]
          : (json['cookies'] as List<dynamic>?)
                  ?.map((dynamic e) => cookieFromJson(e))
                  .toList() ??
              const <Cookie>[],
      proxySettings: UserProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
      userAgent: json['userAgent'],
      thirdPartyCookiesEnabled: json['thirdPartyCookiesEnabled'],
      incognito: isIncognito,
      alwaysOpenHome: isAlwaysOpenHome,
      language: json['language'],
      zoomPercent: clampZoomPercent(
          (json['zoomPercent'] as num?)?.toInt() ?? kDefaultZoomPercent),
      clearUrlEnabled: json['clearUrlEnabled'] ?? true,
      dnsBlockEnabled: json['dnsBlockEnabled'] ?? true,
      contentBlockEnabled: json['contentBlockEnabled'] ?? true,
      trackingProtectionEnabled: json['trackingProtectionEnabled'] ?? true,
      localCdnEnabled: json['localCdnEnabled'] ?? true,
      blockAutoRedirects: json['blockAutoRedirects'] ?? true,
      externalLinksInBrowser: json['externalLinksInBrowser'] as bool? ?? false,
      fullscreenMode: json['fullscreenMode'] ?? false,
      htmlCachingEnabled: json['htmlCachingEnabled'] as bool? ?? false,
      notificationsEnabled:
          (json['notificationsEnabled'] as bool?) ??
              (json['backgroundPoll'] as bool?) ??
              false,
      protectedContentAllowed: json['protectedContentAllowed'] as bool?,
      userScripts: (json['userScripts'] as List<dynamic>?)
          ?.map((e) => UserScriptConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      enabledGlobalScriptIds: (json['enabledGlobalScriptIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      blockedCookies: (json['blockedCookies'] as List<dynamic>?)
          ?.map((e) => BlockedCookie.fromJson(e as Map<String, dynamic>))
          .toSet(),
      locationMode: LocationMode.values.firstWhere(
        (m) => m.name == json['locationMode'],
        orElse: () => LocationMode.off,
      ),
      spoofLatitude: (json['spoofLatitude'] as num?)?.toDouble(),
      spoofLongitude: (json['spoofLongitude'] as num?)?.toDouble(),
      spoofAccuracy: (json['spoofAccuracy'] as num?)?.toDouble() ?? 50.0,
      spoofTimezone: json['spoofTimezone'] as String?,
      spoofTimezoneFromLocation:
          json['spoofTimezoneFromLocation'] as bool? ?? false,
      liveLocationGranularity: _decodeLiveLocationGranularity(
          json['liveLocationGranularity']),
      webRtcPolicy: WebRtcPolicy.values.firstWhere(
        (p) => p.name == json['webRtcPolicy'],
        orElse: () => WebRtcPolicy.defaultPolicy,
      ),
      letterboxEnabled: json['letterboxEnabled'] as bool? ?? false,
      spoofWindowWidth: (json['spoofWindowWidth'] as num?)?.toInt(),
      spoofWindowHeight: (json['spoofWindowHeight'] as num?)?.toInt(),
      fingerprintResetNonce: json['fingerprintResetNonce'] as String?,
      domainClaims: (json['domainClaims'] as List<dynamic>?)
          ?.map((e) => DomainClaim.fromJson(e as Map<String, dynamic>))
          .toList(),
      stateSetterF: stateSetterF,
      isArchiveTier: isArchiveTier,
    )..pageTitle = dropUrl ? null : json['pageTitle'];
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
