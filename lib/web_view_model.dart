import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp show PullToRefreshController, PullToRefreshSettings;
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/profile_cookie_manager.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

export 'package:webspace/settings/location.dart' show LocationMode, WebRtcPolicy;

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
  String? language; // Language code (e.g., 'en', 'es'), null = system default
  bool clearUrlEnabled; // Strip tracking parameters from URLs via ClearURLs
  bool dnsBlockEnabled; // Block navigation to domains on Hagezi DNS blocklist
  bool contentBlockEnabled; // Block ads/trackers via ABP filter list rules
  bool localCdnEnabled; // Serve CDN resources from local cache for privacy
  bool blockAutoRedirects; // Block script-initiated cross-domain navigations
  bool fullscreenMode; // Auto-enter fullscreen when this site is selected
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
  WebRtcPolicy webRtcPolicy;

  /// Whether the webview is currently mid-navigation. Set true on
  /// `onLoadStart`, false on `onLoadStop`. Driven by the
  /// `WebViewConfig.onLoadingChanged` callback wired in [getWebView].
  /// Consumed by the URL-bar action button to swap Refresh ↔ Stop
  /// while a load is in flight.
  bool isLoading = false;

  final List<ConsoleLogEntry> consoleLogs = [];
  static const _maxConsoleLogs = 500;
  VoidCallback? onConsoleLogChanged;

  String? defaultUserAgent;
  Function? stateSetterF;
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
    this.language,
    this.clearUrlEnabled = true,
    this.dnsBlockEnabled = true,
    this.contentBlockEnabled = true,
    this.localCdnEnabled = true,
    this.blockAutoRedirects = true,
    this.fullscreenMode = false,
    List<UserScriptConfig>? userScripts,
    Set<String>? enabledGlobalScriptIds,
    Set<BlockedCookie>? blockedCookies,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.stateSetterF,
  })  : userScripts = userScripts ?? [],
        enabledGlobalScriptIds = enabledGlobalScriptIds ?? {},
        blockedCookies = blockedCookies ?? {},
        siteId = siteId ?? _generateSiteId(),
        currentUrl = currentUrl ?? initUrl,
        name = name ?? extractDomain(initUrl),
        proxySettings = proxySettings ?? UserProxySettings(type: ProxyType.DEFAULT);

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
    
    await controller!.setOptions(
      javascriptEnabled: javascriptEnabled,
      userAgent: userAgent.isNotEmpty ? userAgent : null,
      thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
      incognito: incognito,
    );
    // Apply current theme preference
    await controller!.setThemePreference(_currentTheme);
    // Don't call loadUrl here - it's already initialized with the URL
    if (defaultUserAgent == null) {
      try {
        defaultUserAgent = await controller!.getDefaultUserAgent();
      } catch (e) {
        // Silently handle userAgent retrieval failure - this can happen during
        // testing or when webview isn't fully initialized
        defaultUserAgent = '';
      }
    }
  }

  /// Apply proxy settings to the webview.
  ///
  /// Android: routes through the global `inapp.ProxyController`. Takes
  /// effect on next request without reload.
  ///
  /// iOS / macOS: no-op — the per-site proxy is bound to the per-site
  /// `WKWebsiteDataStore` at WebView construction (via
  /// `WebSpaceInAppWebViewSettings.webspaceProxy`). To pick up a runtime
  /// change, the WebView must be rebuilt; see [updateProxySettings].
  Future<void> _applyProxySettings() async {
    final proxyManager = ProxyManager();
    try {
      await proxyManager.setProxySettings(proxySettings);
    } catch (e) {
      LogService.instance.log('WebView', 'Failed to apply proxy settings: $e', level: LogLevel.error);
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
  /// reconstructs it with the new `WebSpaceInAppWebViewSettings.webspaceProxy`
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
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required String? language, LocationMode locationMode, double? spoofLatitude, double? spoofLongitude, double spoofAccuracy, String? spoofTimezone, bool spoofTimezoneFromLocation, WebRtcPolicy webRtcPolicy, required List<UserScriptConfig> userScripts}) launchUrlFunc,
    CookieManager cookieManager,
    ProfileCookieManager? profileCookieManager,
    Function saveFunc, {
    Future<void> Function(int windowId, String url)? onWindowRequested,
    String? language,
    Function(String url, String html)? onHtmlLoaded,
    bool Function()? shouldFetchHtml,
    String? initialHtml,
    bool Function()? isActive,
    Future<bool> Function(String url)? onConfirmScriptFetch,
    Future<void> Function(String url, ExternalUrlInfo info)? onExternalSchemeUrl,
    void Function(String url, VoidCallback continueHere)? onIosUniversalLinkUrl,
    List<UserScriptConfig> globalUserScripts = const [],
  }) {
    if (webview == null) {
      // Use this.language directly to ensure we get the current value from WebViewModel
      final effectiveLanguage = this.language;
      LogService.instance.log('WebView', 'Creating webview for "$name" (siteId: $siteId, initUrl: $initUrl)');
      LogService.instance.log('WebView', 'Language: $effectiveLanguage (param: $language)');
      LogService.instance.log('WebView', 'Using cached HTML: ${initialHtml != null} (${initialHtml?.length ?? 0} bytes)');
      final bool isMobile = Platform.isIOS || Platform.isAndroid;
      final pullToRefreshController = isMobile ? inapp.PullToRefreshController(
        settings: inapp.PullToRefreshSettings(enabled: true),
        onRefresh: () async {
          controller?.reload();
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
      webview = WebViewFactory.createWebView(
        config: WebViewConfig(
          key: UniqueKey(), // Force new widget state when recreating
          siteId: siteId,
          initialUrl: currentUrl,
          javascriptEnabled: javascriptEnabled,
          userAgent: userAgent.isNotEmpty ? userAgent : null,
          thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
          incognito: incognito,
          language: effectiveLanguage, // Use WebViewModel's language, not parameter
          clearUrlEnabled: clearUrlEnabled,
          dnsBlockEnabled: dnsBlockEnabled,
          contentBlockEnabled: contentBlockEnabled,
          localCdnEnabled: localCdnEnabled,
          locationMode: locationMode,
          spoofLatitude: spoofLatitude,
          spoofLongitude: spoofLongitude,
          spoofAccuracy: spoofAccuracy,
          spoofTimezone: spoofTimezone,
          spoofTimezoneFromLocation: spoofTimezoneFromLocation,
          webRtcPolicy: webRtcPolicy,
          // Per-site proxy. Honored at WebView construction on iOS 17+ /
          // macOS 14+ via the patched `preWKWebViewConfiguration` (see
          // PROXY-002 / PROXY-008). Android ignores this and routes
          // through the global `ProxyController` in `_applyProxySettings`.
          proxySettings: proxySettings,
          userScripts: combineUserScripts(globalUserScripts),
          onConfirmScriptFetch: onConfirmScriptFetch,
          onExternalSchemeUrl: onExternalSchemeUrl,
          onIosUniversalLinkUrl: onIosUniversalLinkUrl,
          pullToRefreshController: pullToRefreshController,
          onWindowRequested: onWindowRequested,
          shouldOverrideUrlLoading: (url, hasGesture) {
            LogService.instance.log('WebView', 'shouldOverrideUrlLoading: site="$name" (siteId: $siteId) initUrl=$initUrl request=$url hasGesture=$hasGesture');
            final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
              targetUrl: url,
              initUrl: initUrl,
              hasGesture: hasGesture,
              blockAutoRedirects: blockAutoRedirects,
              isSiteActive: isActive?.call() ?? true,
              lastSameDomainGestureTime: lastSameDomainGestureTime,
              now: DateTime.now(),
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
                LogService.instance.log('WebView', '  -> ALLOW');
                return true;
              case NavigationDecision.blockSilent:
                LogService.instance.log('WebView', '  -> CANCEL (auto-redirect blocked, no user gesture)');
                return false;
              case NavigationDecision.blockSuppressed:
                LogService.instance.log('WebView', '  -> CANCEL (background site, suppressing nested webview)');
                return false;
              case NavigationDecision.blockOpenNested:
                LogService.instance.log('WebView', '  -> CANCEL (opening nested webview)');
                launchUrlFunc(url, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, language: this.language, locationMode: locationMode, spoofLatitude: spoofLatitude, spoofLongitude: spoofLongitude, spoofAccuracy: spoofAccuracy, spoofTimezone: spoofTimezone, spoofTimezoneFromLocation: spoofTimezoneFromLocation, webRtcPolicy: webRtcPolicy, userScripts: combineUserScripts(globalUserScripts));
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
                  LogService.instance.log('WebView', 'onUrlChanged: cross-domain redirect blocked: $url (expected domain: $initDomain)');
                  return;
                case NavigationDecision.blockSuppressed:
                  LogService.instance.log('WebView', 'onUrlChanged: cross-domain redirect suppressed (background site): $url');
                  return;
                case NavigationDecision.blockOpenNested:
                  LogService.instance.log('WebView', 'onUrlChanged: cross-domain redirect detected: $url (expected domain: $initDomain)');
                  if (handled.launchNestedUrl != null) {
                    launchUrlFunc(handled.launchNestedUrl!, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, language: this.language, locationMode: locationMode, spoofLatitude: spoofLatitude, spoofLongitude: spoofLongitude, spoofAccuracy: spoofAccuracy, spoofTimezone: spoofTimezone, spoofTimezoneFromLocation: spoofTimezoneFromLocation, webRtcPolicy: webRtcPolicy, userScripts: combineUserScripts(globalUserScripts));
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
          // manager is active for this engine. Profile mode hits the
          // per-site profile via the patched plugin's
          // `webViewController:`; legacy mode hits the global jar.
          cookieManager: cookieManager,
          profileCookieManager: profileCookieManager,
          cookieSiteId: siteId,
          onCookiesChanged: (newCookies) async {
            // Remove blocked cookies from the webview cookie jar
            if (blockedCookies.isNotEmpty) {
              final blocked = newCookies.where((c) => isCookieBlocked(c.name, c.domain)).toList();
              final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : initUrl);
              for (final c in blocked) {
                if (profileCookieManager != null) {
                  await profileCookieManager.deleteCookie(
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
          LogService.instance.log('WebView', 'onControllerCreated for "$name" (siteId: $siteId)');
          controller = ctrl;
          setController();
        },
      );
    }
    return webview!;
  }

  WebViewController? getController(
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required String? language, LocationMode locationMode, double? spoofLatitude, double? spoofLongitude, double spoofAccuracy, String? spoofTimezone, bool spoofTimezoneFromLocation, WebRtcPolicy webRtcPolicy, required List<UserScriptConfig> userScripts}) launchUrlFunc,
    CookieManager cookieManager,
    ProfileCookieManager? profileCookieManager,
    Function saveFunc, {
    List<UserScriptConfig> globalUserScripts = const [],
  }) {
    if (webview == null) {
      // Create webview with current language setting
      webview = getWebView(launchUrlFunc, cookieManager, profileCookieManager, saveFunc, language: language, globalUserScripts: globalUserScripts);
    }
    if (controller != null) {
      setController();
    }
    return controller;
  }

  Future<void> deleteCookies(CookieManager cookieManager,
      ProfileCookieManager? profileCookieManager) async {
    final url = Uri.parse(initUrl);
    for (final Cookie cookie in cookies) {
      if (profileCookieManager != null) {
        await profileCookieManager.deleteCookie(
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
  Future<void> pauseWebView() async {
    if (controller == null) return;
    try {
      await controller!.pause();
      LogService.instance.log('WebView', 'Paused webview for "$name" (siteId: $siteId)');
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Resume a previously paused webview when it becomes active again.
  Future<void> resumeWebView() async {
    if (controller == null) return;
    try {
      await controller!.resume();
      LogService.instance.log('WebView', 'Resumed webview for "$name" (siteId: $siteId)');
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
    if (controller == null) return;
    try {
      await controller!.pause();
      await controller!.pauseAllJsTimers();
      LogService.instance.log('WebView', 'App-lifecycle paused webview for "$name" (siteId: $siteId)');
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Inverse of [pauseForAppLifecycle].
  Future<void> resumeFromAppLifecycle() async {
    if (controller == null) return;
    try {
      await controller!.resume();
      await controller!.resumeAllJsTimers();
      LogService.instance.log('WebView', 'App-lifecycle resumed webview for "$name" (siteId: $siteId)');
    } catch (_) {
      // Controller may have been disposed
    }
  }

  /// Dispose the webview and controller to release resources.
  /// Used when unloading a site due to domain conflict.
  void disposeWebView() {
    LogService.instance.log('WebView', 'disposeWebView called for "$name" (siteId: $siteId)');
    webview = null;
    controller = null;
  }

  /// Get display name - uses the name field (which auto-updates from page title)
  String getDisplayName() {
    return name;
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'initUrl': initUrl,
        'currentUrl': currentUrl,
        'name': name,
        'pageTitle': pageTitle,
        'cookies': cookies.map((cookie) => cookie.toJson()).toList(),
        'proxySettings': proxySettings.toJson(),
        'javascriptEnabled': javascriptEnabled,
        'userAgent': userAgent,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'incognito': incognito,
        'language': language,
        'clearUrlEnabled': clearUrlEnabled,
        'dnsBlockEnabled': dnsBlockEnabled,
        'contentBlockEnabled': contentBlockEnabled,
        'localCdnEnabled': localCdnEnabled,
        'blockAutoRedirects': blockAutoRedirects,
        'fullscreenMode': fullscreenMode,
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
        'webRtcPolicy': webRtcPolicy.name,
      };

  factory WebViewModel.fromJson(Map<String, dynamic> json, Function? stateSetterF) {
    return WebViewModel(
      siteId: json['siteId'], // May be null for legacy data, will auto-generate
      initUrl: json['initUrl'],
      currentUrl: json['currentUrl'],
      name: json['name'],
      cookies: (json['cookies'] as List<dynamic>)
          .map((dynamic e) => cookieFromJson(e))
          .toList(),
      proxySettings: UserProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
      userAgent: json['userAgent'],
      thirdPartyCookiesEnabled: json['thirdPartyCookiesEnabled'],
      incognito: json['incognito'] ?? false,
      language: json['language'],
      clearUrlEnabled: json['clearUrlEnabled'] ?? true,
      dnsBlockEnabled: json['dnsBlockEnabled'] ?? true,
      contentBlockEnabled: json['contentBlockEnabled'] ?? true,
      localCdnEnabled: json['localCdnEnabled'] ?? true,
      blockAutoRedirects: json['blockAutoRedirects'] ?? true,
      fullscreenMode: json['fullscreenMode'] ?? false,
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
      webRtcPolicy: WebRtcPolicy.values.firstWhere(
        (p) => p.name == json['webRtcPolicy'],
        orElse: () => WebRtcPolicy.defaultPolicy,
      ),
      stateSetterF: stateSetterF,
    )..pageTitle = json['pageTitle'];
  }
}
