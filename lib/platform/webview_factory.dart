import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webview_cef/webview_cef.dart' as cef;
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

/// WebviewCef controller wrapper
class _WebViewCefController implements UnifiedWebViewController {
  final cef.WebViewController controller;
  String _currentUrl = '';

  _WebViewCefController(this.controller);

  @override
  Future<void> loadUrl(String url) async {
    _currentUrl = url;
    await controller.loadUrl(url); // loadUrl for subsequent loads
  }

  @override
  Future<void> reload() async {
    await controller.reload();
  }

  @override
  Future<Uri?> getUrl() async {
    return _currentUrl.isNotEmpty ? Uri.tryParse(_currentUrl) : null;
  }

  @override
  Future<String?> getTitle() async {
    // webview_cef doesn't expose getTitle API, but we can inject a callback
    // Use a workaround: inject JavaScript that sets the title in the URL hash temporarily
    try {
      // Create a unique callback ID
      final callbackId = 'getTitleCallback_${DateTime.now().millisecondsSinceEpoch}';
      
      // Inject JavaScript to get the title
      // We'll store it in a global variable that can be accessed
      await controller.executeJavaScript('''
        (function() {
          window._webspace_page_title = document.title;
        })();
      ''');
      
      // Wait a bit for JS to execute
      await Future.delayed(Duration(milliseconds: 50));
      
      // Unfortunately, webview_cef's executeJavaScript doesn't return values
      // So we can't retrieve the title this way
      // Return null and let the name default to domain
      return null;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> evaluateJavascript(String source) async {
    await controller.executeJavaScript(source);
  }

  @override
  Future<void> findAllAsync({required String find}) async {
    // webview_cef doesn't support find in page yet
  }

  @override
  Future<void> findNext({required bool forward}) async {
    // webview_cef doesn't support find in page yet
  }

  @override
  Future<void> clearMatches() async {
    // webview_cef doesn't support find in page yet
  }

  @override
  Future<String?> getDefaultUserAgent() async {
    return 'Mozilla/5.0'; // webview_cef doesn't expose default UA
  }

  @override
  Future<void> setOptions({required bool javascriptEnabled, String? userAgent}) async {
    // webview_cef doesn't have runtime options API
    // Settings are applied during initialization
  }

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
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

/// Factory for creating platform-specific webviews
class WebViewFactory {
  static bool _cefInitialized = false;

  /// Create a webview widget based on the current platform
  static Widget createWebView({
    required WebViewConfig config,
    required Function(UnifiedWebViewController) onControllerCreated,
  }) {
    if (PlatformInfo.useInAppWebView) {
      return _createInAppWebView(config, onControllerCreated);
    } else if (PlatformInfo.useWebViewCef) {
      return _createWebViewCef(config, onControllerCreated);
    } else {
      return Center(
        child: Text('WebView not supported on this platform'),
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

  static Widget _createWebViewCef(
    WebViewConfig config,
    Function(UnifiedWebViewController) onControllerCreated,
  ) {
    // Initialize webview_cef manager once
    if (!_cefInitialized) {
      // Note: The threading warning is a known issue in webview_cef plugin
      // It doesn't affect functionality but should be fixed upstream
      cef.WebviewManager().initialize(
        userAgent: config.userAgent ?? 'Mozilla/5.0',
      );
      _cefInitialized = true;
    }

    final controller = cef.WebviewManager().createWebView(
      loading: const Center(child: CircularProgressIndicator()),
    );

    controller.setWebviewListener(cef.WebviewEventsListener(
      onUrlChanged: (url) {
        if (config.onUrlChanged != null) {
          config.onUrlChanged!(url);
        }
      },
      onLoadStart: (ctrl, url) {
        // Load started
      },
      onLoadEnd: (ctrl, url) {
        // Load finished - trigger URL change callback to fetch title
        if (url != null && config.onUrlChanged != null) {
          config.onUrlChanged!(url);
        }
      },
    ));

    // Initialize the webview with the URL
    Future.microtask(() async {
      await controller.initialize(config.initialUrl);
      final unifiedController = _WebViewCefController(controller);
      onControllerCreated(unifiedController);
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        return ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, child) {
            final widget = controller.value
                ? controller.webviewWidget
                : controller.loadingWidget;
            
            // Force the webview to fill available space and respond to resizes
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: widget,
            );
          },
        );
      },
    );
  }
}
