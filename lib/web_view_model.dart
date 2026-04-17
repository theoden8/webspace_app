import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show ConsoleMessageLevel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp show PullToRefreshController, PullToRefreshSettings;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

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
  Set<BlockedCookie> blockedCookies; // Per-site blocked cookies (name + domain)

  final List<ConsoleLogEntry> consoleLogs = [];
  static const _maxConsoleLogs = 500;
  VoidCallback? onConsoleLogChanged;

  String? defaultUserAgent;
  Function? stateSetterF;
  FindMatchesResult findMatches = FindMatchesResult();
  WebViewTheme _currentTheme = WebViewTheme.light;

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
    Set<BlockedCookie>? blockedCookies,
    this.stateSetterF,
  })  : userScripts = userScripts ?? [],
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

  /// Apply proxy settings to the webview
  Future<void> _applyProxySettings() async {
    final proxyManager = ProxyManager();
    try {
      await proxyManager.setProxySettings(proxySettings);
    } catch (e) {
      LogService.instance.log('WebView', 'Failed to apply proxy settings: $e', level: LogLevel.error);
    }
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

  /// Update proxy settings and apply them
  Future<void> updateProxySettings(UserProxySettings newSettings) async {
    proxySettings = newSettings;
    await _applyProxySettings();
  }

  Widget getWebView(
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required String? language}) launchUrlFunc,
    CookieManager cookieManager,
    Function saveFunc, {
    Future<void> Function(int windowId, String url)? onWindowRequested,
    String? language,
    Function(String url, String html)? onHtmlLoaded,
    String? initialHtml,
    bool Function()? isActive,
    Future<bool> Function(String url)? onConfirmScriptFetch,
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
      // Guard against re-entrant cross-domain redirect handling from
      // onUrlChanged (called by both onUpdateVisitedHistory and onLoadStop).
      bool redirectHandled = false;
      // The URL before the most recent same-domain navigation, used to
      // navigate back when a cross-domain redirect is detected.
      String? previousSameDomainUrl;
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
          userScripts: [...globalUserScripts, ...userScripts],
          onConfirmScriptFetch: onConfirmScriptFetch,
          pullToRefreshController: pullToRefreshController,
          onWindowRequested: onWindowRequested,
          shouldOverrideUrlLoading: (url, hasGesture) {
            // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile iframes
            if (url == 'about:blank' || url == 'about:srcdoc') {
              LogService.instance.log('WebView', 'shouldOverrideUrlLoading: ALLOW $url (captcha iframe support)');
              return true;
            }

            // Allow data: and blob: URIs - these are inline content with no
            // real domain (e.g. DuckDuckGo uses data: URIs internally).
            final scheme = Uri.tryParse(url)?.scheme ?? '';
            if (scheme == 'data' || scheme == 'blob') {
              LogService.instance.log('WebView', 'shouldOverrideUrlLoading: ALLOW $url (inline $scheme: URI)');
              return true;
            }

            // Use normalized domain comparison (handles aliases like mail.google.com -> gmail.com)
            final requestNormalized = getNormalizedDomain(url);
            final initialNormalized = getNormalizedDomain(initUrl);

            LogService.instance.log('WebView', 'shouldOverrideUrlLoading: site="$name" (siteId: $siteId) initUrl=$initUrl request=$url from=$initialNormalized to=$requestNormalized hasGesture=$hasGesture');

            if (requestNormalized == initialNormalized) {
              if (hasGesture) {
                lastSameDomainGestureTime = DateTime.now();
              }
              LogService.instance.log('WebView', '  -> ALLOW (same domain)');
              return true; // Allow - same logical domain
            }

            // For cross-domain navigations without gesture, check if this
            // is a redirect from a recent user-clicked same-domain URL
            // (e.g., search engine redirect: DDG /l/?uddg=..., Google /url?q=...).
            // Propagate the gesture so the redirect opens a nested webview
            // instead of being silently blocked.
            bool effectiveHasGesture = hasGesture;
            if (!hasGesture && lastSameDomainGestureTime != null) {
              final elapsed = DateTime.now().difference(lastSameDomainGestureTime!);
              if (elapsed.inSeconds < 10) {
                effectiveHasGesture = true;
                LogService.instance.log('WebView', '  -> Gesture propagated from same-domain click ${elapsed.inMilliseconds}ms ago');
              }
              lastSameDomainGestureTime = null; // Consume — only propagate once
            }

            // Block script-initiated cross-domain navigations (Google One Tap, Stripe, etc.)
            if (blockAutoRedirects && !effectiveHasGesture) {
              LogService.instance.log('WebView', '  -> CANCEL (auto-redirect blocked, no user gesture)');
              return false;
            }

            // Only open nested webview if this site is currently active.
            // In IndexedStack, background sites remain alive and can fire
            // shouldOverrideUrlLoading — don't open dialogs for them.
            if (isActive != null && !isActive()) {
              LogService.instance.log('WebView', '  -> CANCEL (background site, suppressing nested webview)');
              return false;
            }

            // Open in nested webview with home site title
            LogService.instance.log('WebView', '  -> CANCEL (opening nested webview)');
            launchUrlFunc(url, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, language: this.language);
            return false; // Cancel
          },
          onUrlChanged: (url) async {
            // Detect cross-domain redirects that bypassed shouldOverrideUrlLoading
            // (e.g., server-side 302 from search engine redirect pages like
            // DuckDuckGo's /l/?uddg=... or Google's /url?q=...).

            // Skip non-HTTP(S) URIs — these are inline content or browser
            // internals, not cross-domain navigations.
            final urlScheme = Uri.tryParse(url)?.scheme ?? '';
            if (urlScheme == 'data' || urlScheme == 'blob' || urlScheme == 'about') {
              return;
            }

            final urlDomain = getNormalizedDomain(url);
            final initDomain = getNormalizedDomain(initUrl);
            if (urlDomain != initDomain
                && !WebViewFactory.isCaptchaChallenge(url)
                && !redirectHandled) {
              redirectHandled = true;

              // Check gesture propagation (same logic as shouldOverrideUrlLoading)
              bool hasRecentGesture = false;
              if (lastSameDomainGestureTime != null) {
                final elapsed = DateTime.now().difference(lastSameDomainGestureTime!);
                if (elapsed.inSeconds < 10) {
                  hasRecentGesture = true;
                }
                lastSameDomainGestureTime = null; // Consume
              }

              // Navigate back to the last same-domain page
              if (controller != null) {
                controller!.loadUrl(previousSameDomainUrl ?? initUrl);
              }

              if (blockAutoRedirects && !hasRecentGesture) {
                // Silently block — no nested webview
                LogService.instance.log('WebView', 'onUrlChanged: cross-domain redirect blocked: $url (expected domain: $initDomain)');
                return;
              }

              LogService.instance.log('WebView', 'onUrlChanged: cross-domain redirect detected: $url (expected domain: $initDomain)');
              // Open in nested webview if this site is active
              if (isActive == null || isActive()) {
                launchUrlFunc(url, homeTitle: name, siteId: siteId, incognito: incognito, thirdPartyCookiesEnabled: thirdPartyCookiesEnabled, clearUrlEnabled: clearUrlEnabled, dnsBlockEnabled: dnsBlockEnabled, contentBlockEnabled: contentBlockEnabled, language: this.language);
              }
              return;
            }
            if (urlDomain == initDomain) {
              redirectHandled = false;
              previousSameDomainUrl = currentUrl;
            }

            currentUrl = url;
            // Trigger UI rebuild so URL bar updates
            if (stateSetterF != null) {
              stateSetterF!();
            }
            // Get page title and update name if we have a title
            if (controller != null) {
              var title = await controller!.getTitle();

              // Fallback: If controller doesn't provide title,
              // parse HTML to extract it
              if (title == null || title.isEmpty) {
                // Import getPageTitle from main.dart would cause circular dependency
                // So we'll handle this in the UI layer instead
              } else {
                pageTitle = title;
                // Auto-update name from page title if name is still the default domain
                if (name == extractDomain(initUrl)) {
                  name = title;
                }
              }

              // Reapply theme after page load (some sites might override it)
              await controller!.setThemePreference(_currentTheme);
            }
            await saveFunc();
          },
          onCookiesChanged: (newCookies) async {
            // Remove blocked cookies from the webview cookie jar
            if (blockedCookies.isNotEmpty) {
              final blocked = newCookies.where((c) => isCookieBlocked(c.name, c.domain)).toList();
              final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : initUrl);
              for (final c in blocked) {
                await cookieManager.deleteCookie(
                  url: url,
                  name: c.name,
                  domain: c.domain,
                  path: c.path ?? '/',
                );
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
    Function(String url, {String? homeTitle, required String? siteId, required bool incognito, required bool thirdPartyCookiesEnabled, required bool clearUrlEnabled, required bool dnsBlockEnabled, required bool contentBlockEnabled, required String? language}) launchUrlFunc,
    CookieManager cookieManager,
    Function saveFunc, {
    List<UserScriptConfig> globalUserScripts = const [],
  }) {
    if (webview == null) {
      // Create webview with current language setting
      webview = getWebView(launchUrlFunc, cookieManager, saveFunc, language: language, globalUserScripts: globalUserScripts);
    }
    if (controller != null) {
      setController();
    }
    return controller;
  }

  Future<void> deleteCookies(CookieManager cookieManager) async {
    for (final Cookie cookie in cookies) {
      await cookieManager.deleteCookie(
        url: Uri.parse(initUrl),
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? "/",
      );
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

  /// Pause the webview to reduce resource usage when in background.
  /// Stops rendering (Android) and JS timers. The webview remains in the
  /// widget tree but consumes minimal resources.
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
        if (blockedCookies.isNotEmpty)
          'blockedCookies': blockedCookies.map((b) => b.toJson()).toList(),
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
      blockedCookies: (json['blockedCookies'] as List<dynamic>?)
          ?.map((e) => BlockedCookie.fromJson(e as Map<String, dynamic>))
          .toSet(),
      stateSetterF: stateSetterF,
    )..pageTitle = json['pageTitle'];
  }
}
