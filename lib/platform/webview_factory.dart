import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
// webview_cef support has been removed
// import 'package:webview_cef/webview_cef.dart' as cef;
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
    return await inapp.InAppWebViewController.getDefaultUserAgent();
  }

  @override
  Future<void> setOptions({required bool javascriptEnabled, String? userAgent}) async {
    await controller.setOptions(
      options: inapp.InAppWebViewGroupOptions(
        crossPlatform: inapp.InAppWebViewOptions(
          javaScriptEnabled: javascriptEnabled,
          userAgent: userAgent ?? '',
          supportZoom: true,
          useShouldOverrideUrlLoading: true,
        ),
      ),
    );
  }

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
    // For Android, we can use the forceDark setting (API 29+)
    // However, this requires Android settings which are platform-specific
    // Instead, we'll inject JavaScript to set the theme via CSS
    String themeValue = theme == WebViewTheme.dark ? 'dark' : 'light';
    
    await evaluateJavascript('''
      (function() {
        // Set color-scheme meta tag if it doesn't exist
        let metaTag = document.querySelector('meta[name="color-scheme"]');
        if (!metaTag) {
          metaTag = document.createElement('meta');
          metaTag.name = 'color-scheme';
          document.head.appendChild(metaTag);
        }
        metaTag.content = '$themeValue';
        
        // Also set it on the root element for maximum compatibility
        document.documentElement.style.colorScheme = '$themeValue';
      })();
    ''');
  }
}

// WebviewCef controller has been removed
// webview_cef support is no longer included in this application

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
      // webview_cef has been disabled
      return Center(
        child: Text('WebView not supported on this platform.\nLinux builds are currently disabled.'),
      );
    }
  }

  static Widget _createInAppWebView(
    WebViewConfig config,
    Function(UnifiedWebViewController) onControllerCreated,
  ) {
    final cookieManager = UnifiedCookieManager();

    return inapp.InAppWebView(
      initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(config.initialUrl)),
      initialOptions: inapp.InAppWebViewGroupOptions(
        crossPlatform: inapp.InAppWebViewOptions(
          javaScriptEnabled: config.javascriptEnabled,
          userAgent: config.userAgent ?? '',
          supportZoom: true,
          useShouldOverrideUrlLoading: true,
        ),
      ),
      onWebViewCreated: (controller) {
        onControllerCreated(_InAppWebViewController(controller));
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url.toString();
        if (config.shouldOverrideUrlLoading != null) {
          final shouldAllow = config.shouldOverrideUrlLoading!(url, true);
          return shouldAllow
              ? inapp.NavigationActionPolicy.ALLOW
              : inapp.NavigationActionPolicy.CANCEL;
        }
        return inapp.NavigationActionPolicy.ALLOW;
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

