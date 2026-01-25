import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'platform_info.dart';
import 'unified_webview.dart';

/// Configuration for creating a webview
class WebViewConfig {
  final String initialUrl;
  final bool javascriptEnabled;
  final String? userAgent;
  final Function(String url)? onUrlChanged;
  final Function(List<UnifiedCookie> cookies)? onCookiesChanged;
  final Function(int activeMatch, int totalMatches)? onFindResult;
  final Function(String url, bool shouldAllow)? shouldOverrideUrlLoading;

  WebViewConfig({
    required this.initialUrl,
    this.javascriptEnabled = true,
    this.userAgent,
    this.onUrlChanged,
    this.onCookiesChanged,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
  });
}

/// Controller interface that abstracts platform-specific controllers
abstract class UnifiedWebViewController {
  Future<void> loadUrl(String url);
  Future<void> reload();
  Future<Uri?> getUrl();
  Future<String?> getTitle();
  Future<void> evaluateJavascript(String source);
  Future<void> findAllAsync({required String find});
  Future<void> findNext({required bool forward});
  Future<void> clearMatches();
  Future<String?> getDefaultUserAgent();
  Future<void> setOptions({required bool javascriptEnabled, String? userAgent});
  Future<void> setThemePreference(WebViewTheme theme);
  Future<void> goBack();
  Future<bool> canGoBack();
}

/// InAppWebView controller wrapper
class _InAppWebViewController implements UnifiedWebViewController {
  final inapp.InAppWebViewController controller;

  _InAppWebViewController(this.controller);

  @override
  Future<void> loadUrl(String url) async {
    await controller.loadUrl(
      urlRequest: inapp.URLRequest(url: inapp.WebUri(url)),
    );
  }

  @override
  Future<void> reload() async {
    await controller.reload();
  }

  @override
  Future<Uri?> getUrl() async {
    return await controller.getUrl();
  }

  @override
  Future<String?> getTitle() async {
    return await controller.getTitle();
  }

  @override
  Future<void> evaluateJavascript(String source) async {
    await controller.evaluateJavascript(source: source);
  }

  @override
  Future<void> findAllAsync({required String find}) async {
    await controller.findAllAsync(find: find);
  }

  @override
  Future<void> findNext({required bool forward}) async {
    await controller.findNext(forward: forward);
  }

  @override
  Future<void> clearMatches() async {
    await controller.clearMatches();
  }

  @override
  Future<String?> getDefaultUserAgent() async {
    try {
      return await inapp.InAppWebViewController.getDefaultUserAgent();
    } catch (e) {
      // Return null if userAgent retrieval fails (can happen during testing
      // or when webview isn't fully initialized)
      return null;
    }
  }

  @override
  Future<void> setOptions({required bool javascriptEnabled, String? userAgent}) async {
    await controller.setSettings(
      settings: inapp.InAppWebViewSettings(
        javaScriptEnabled: javascriptEnabled,
        userAgent: userAgent ?? '',
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: false,
      ),
    );
  }

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
    // Determine the actual theme value to apply
    String themeValue;
    if (theme == WebViewTheme.system) {
      // For system theme, detect the OS preference via matchMedia
      // This will be evaluated in the webview's JavaScript context
      themeValue = 'system';
    } else {
      themeValue = theme == WebViewTheme.dark ? 'dark' : 'light';
    }

    await evaluateJavascript('''
      (function() {
        // Determine the actual theme to apply
        let actualTheme = '$themeValue';
        if (actualTheme === 'system') {
          // Detect system preference using the browser's native matchMedia
          // This must be done before we override matchMedia
          actualTheme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
        }

        // Store the app's theme preference globally
        window.__appThemePreference = actualTheme;

        // Store the original matchMedia function if not already stored
        if (!window.__originalMatchMedia) {
          window.__originalMatchMedia = window.matchMedia.bind(window);
        }

        // Override window.matchMedia to expose app theme to websites
        window.matchMedia = function(query) {
          // Call original matchMedia first
          const originalResult = window.__originalMatchMedia(query);

          // Check if this is a prefers-color-scheme query
          if (query.includes('prefers-color-scheme')) {
            const isDarkQuery = query.includes('dark');
            const isLightQuery = query.includes('light');
            const appIsDark = window.__appThemePreference === 'dark';

            // Determine if this query matches based on app theme
            let matches = false;
            if (isDarkQuery) {
              matches = appIsDark;
            } else if (isLightQuery) {
              matches = !appIsDark;
            }

            // Create a fake MediaQueryList object
            const fakeResult = {
              matches: matches,
              media: query,
              onchange: null,

              // Support addEventListener for 'change' events
              addEventListener: function(type, listener, options) {
                if (type === 'change') {
                  if (!window.__themeChangeListeners) {
                    window.__themeChangeListeners = [];
                  }
                  window.__themeChangeListeners.push({ query: query, listener: listener });
                }
              },

              // Support removeEventListener
              removeEventListener: function(type, listener, options) {
                if (type === 'change' && window.__themeChangeListeners) {
                  window.__themeChangeListeners = window.__themeChangeListeners.filter(
                    item => item.listener !== listener
                  );
                }
              },

              // Support deprecated addListener method
              addListener: function(listener) {
                this.addEventListener('change', listener);
              },

              // Support deprecated removeListener method
              removeListener: function(listener) {
                this.removeEventListener('change', listener);
              }
            };

            return fakeResult;
          }

          // For non-theme queries, return the original result
          return originalResult;
        };

        // Set color-scheme meta tag
        let metaTag = document.querySelector('meta[name="color-scheme"]');
        if (!metaTag) {
          metaTag = document.createElement('meta');
          metaTag.name = 'color-scheme';
          document.head.appendChild(metaTag);
        }
        metaTag.content = actualTheme;

        // Set color-scheme CSS property on root element
        document.documentElement.style.colorScheme = actualTheme;

        // Notify any registered listeners about the theme change
        if (window.__themeChangeListeners) {
          window.__themeChangeListeners.forEach(item => {
            const isDarkQuery = item.query.includes('dark');
            const isLightQuery = item.query.includes('light');
            const appIsDark = window.__appThemePreference === 'dark';

            let matches = false;
            if (isDarkQuery) {
              matches = appIsDark;
            } else if (isLightQuery) {
              matches = !appIsDark;
            }

            // Create event object
            const event = {
              matches: matches,
              media: item.query
            };

            try {
              item.listener(event);
            } catch (e) {
              console.error('Error in theme change listener:', e);
            }
          });
        }
      })();
    ''');
  }

  @override
  Future<void> goBack() async {
    await controller.goBack();
  }

  @override
  Future<bool> canGoBack() async {
    return await controller.canGoBack();
  }
}

/// Factory for creating platform-specific webviews
class WebViewFactory {
  /// Create a webview widget based on the current platform
  static Widget createWebView({
    required WebViewConfig config,
    required Function(UnifiedWebViewController) onControllerCreated,
  }) {
    if (PlatformInfo.useInAppWebView) {
      return _createInAppWebView(config, onControllerCreated);
    } else {
      return Center(
        child: Text('WebView not supported on this platform.\nLinux builds are currently disabled.'),
      );
    }
  }

  /// Check if a URL should be blocked (tracking, analytics, service workers, etc.)
  static bool _shouldBlockUrl(String url) {
    // Block about: URLs (about:blank, about:srcdoc, etc.)
    if (url.startsWith('about:')) {
      return true;
    }

    // Block service worker iframes and tracking iframes
    if (url.contains('/sw_iframe.html') ||
        url.contains('/blank.html') ||
        url.contains('/service_worker/')) {
      return true;
    }

    // Block common tracking and analytics domains
    final trackingDomains = [
      'googletagmanager.com',
      'google-analytics.com',
      'googleadservices.com',
      'doubleclick.net',
      'facebook.com/tr',
      'connect.facebook.net',
      'analytics.twitter.com',
      'static.ads-twitter.com',
    ];

    for (final domain in trackingDomains) {
      if (url.contains(domain)) {
        return true;
      }
    }

    return false;
  }

  /// Check if a URL is a Cloudflare challenge that needs user interaction
  static bool _isCloudflareChallenge(String url) {
    return url.contains('challenges.cloudflare.com') ||
           url.contains('cloudflare.com/cdn-cgi/challenge');
  }

  static Widget _createInAppWebView(
    WebViewConfig config,
    Function(UnifiedWebViewController) onControllerCreated,
  ) {
    final cookieManager = UnifiedCookieManager();

    return inapp.InAppWebView(
      initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(config.initialUrl)),
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: config.javascriptEnabled,
        userAgent: config.userAgent ?? '',
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: false,
      ),
      onWebViewCreated: (controller) {
        onControllerCreated(_InAppWebViewController(controller));
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url.toString();

        // Block tracking, analytics, and service worker URLs
        if (_shouldBlockUrl(url)) {
          return inapp.NavigationActionPolicy.CANCEL;
        }

        // Always allow Cloudflare challenge URLs to navigate in the main webview
        // They will redirect back after completion
        if (_isCloudflareChallenge(url)) {
          return inapp.NavigationActionPolicy.ALLOW;
        }

        if (config.shouldOverrideUrlLoading != null) {
          final shouldAllow = config.shouldOverrideUrlLoading!(url, true);
          return shouldAllow
              ? inapp.NavigationActionPolicy.ALLOW
              : inapp.NavigationActionPolicy.CANCEL;
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        // Check the URL being opened in a new window
        final url = createWindowAction.request.url?.toString() ?? '';

        // Allow Cloudflare challenges to load in the main webview instead of nested
        // These need user interaction, so we redirect to the main webview
        if (_isCloudflareChallenge(url)) {
          await controller.loadUrl(
            urlRequest: inapp.URLRequest(url: createWindowAction.request.url),
          );
          return null; // Don't create nested window
        }

        // Block all other nested window creation attempts
        // This includes tracking URLs, popups, about:blank, service workers, etc.
        return null;
      },
      onLoadStop: (controller, url) async {
        if (url != null) {
          if (config.onUrlChanged != null) {
            config.onUrlChanged!(url.toString());
          }
          if (config.onCookiesChanged != null) {
            final cookies = await cookieManager.getCookies(url: url);
            config.onCookiesChanged!(cookies);
          }
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        if (config.onFindResult != null) {
          config.onFindResult!(activeMatchOrdinal, numberOfMatches);
        }
      },
    );
  }
}
