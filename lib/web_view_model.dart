import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'settings/proxy.dart';
import 'find_toolbar.dart';

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

Cookie cookieFromJson(Map<String, dynamic> json) {
  return Cookie(
    name: json["name"],
    value: json["value"],
    expiresDate: json["expiresDate"],
    isSessionOnly: json["isSessionOnly"],
    domain: json["domain"],
    sameSite: json["sameSite?.toValue()"],
    isSecure: json["isSecure"],
    isHttpOnly: json["isHttpOnly"],
    path: json["path"],
  );
}


class WebViewModel {
  final String initUrl;
  String currentUrl;
  List<Cookie> cookies;
  InAppWebView? webview;
  InAppWebViewController? controller;
  ProxySettings proxySettings;
  bool javascriptEnabled;
  String userAgent;
  bool thirdPartyCookiesEnabled;

  String? defaultUserAgent;
  Function? stateSetterF;
  FindMatchesResult findMatches = FindMatchesResult();

  WebViewModel({
    required this.initUrl,
    String? currentUrl,
    this.cookies=const [],
    ProxySettings? proxySettings,
    this.javascriptEnabled=true,
    this.userAgent='',
    this.thirdPartyCookiesEnabled=false,
    this.stateSetterF,
  }):
    currentUrl = currentUrl ?? initUrl,
    proxySettings = proxySettings ?? ProxySettings(type: ProxyType.DEFAULT);

  void removeThirdPartyCookies(InAppWebViewController controller) async {
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

    await controller.evaluateJavascript(source: script);
  }

  void setController() {
    if (controller == null) {
      return;
    }
    controller!.setOptions(options: InAppWebViewGroupOptions(
      crossPlatform: InAppWebViewOptions(
        javaScriptEnabled: javascriptEnabled,
        userAgent: userAgent,
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
      ),
    ));
    controller!.loadUrl(urlRequest: URLRequest(url: Uri.parse(currentUrl)));
    if(defaultUserAgent == null) {
      InAppWebViewController.getDefaultUserAgent().then((String value) {
        defaultUserAgent = value;
      });
    }
  }

  InAppWebView getWebView(launch_url_func, CookieManager cookieManager, save_func) {
    if (webview == null) {
      webview = InAppWebView(
        initialUrlRequest: URLRequest(url: Uri.parse(currentUrl)),
        onWebViewCreated: (controller) {
          this.controller = controller;
          setController();
        },
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          String requestDomain = extractDomain(navigationAction.request.url.toString());
          String initialDomain = extractDomain(initUrl);

          // Extract top-level and second-level domains
          List<String> requestDomainParts = requestDomain.split('.');
          List<String> initialDomainParts = initialDomain.split('.');

          // Compare top-level and second-level domains
          bool sameTopLevelDomain = requestDomainParts.last == initialDomainParts.last;
          bool sameSecondLevelDomain = requestDomainParts[requestDomainParts.length - 2] ==
              initialDomainParts[initialDomainParts.length - 2];

          if (sameTopLevelDomain && sameSecondLevelDomain) {
            return NavigationActionPolicy.ALLOW;
          } else {
            await launch_url_func(navigationAction.request.url.toString());
            return NavigationActionPolicy.CANCEL;
          }
        },
        onLoadStop: (controller, Uri? url) async {
          if(url == null) {
            return;
          }
          cookies = await cookieManager.getCookies(url: Uri.parse(currentUrl));
          if(!thirdPartyCookiesEnabled) {
            removeThirdPartyCookies(controller!);
          }
          currentUrl = url!.toString();
          await save_func();
        },
        onFindResultReceived: (controller, int activeMatchOrdinal, int numberOfMatches, bool isDoneCounting) {
          findMatches.activeMatchOrdinal = activeMatchOrdinal;
          findMatches.numberOfMatches = numberOfMatches;
          if(stateSetterF != null) {
            stateSetterF!();
          }
        },
      );
    }
    return webview!;
  }

  InAppWebViewController? getController(launch_url_func, CookieManager cookieManager, savefunc) {
    if (webview == null) {
      webview = getWebView(launch_url_func, cookieManager, savefunc);
    }
    if (controller == null) {
      return null;
    }
    setController();
    return controller!;
  }

  void deleteCookies(CookieManager cookieManager) async {
    for(final Cookie cookie in cookies) {
      await cookieManager.deleteCookie(
        url: Uri.parse(initUrl),
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? "/",
      );
    }
    cookies = [];
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
    'initUrl': initUrl,
    'currentUrl': currentUrl,
    'cookies': cookies.map((cookie) => cookie.toJson()).toList(),
    'proxySettings': proxySettings.toJson(),
    'javascriptEnabled': javascriptEnabled,
    'userAgent': userAgent,
    'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
  };

  factory WebViewModel.fromJson(Map<String, dynamic> json, Function? stateSetterF) {
    return WebViewModel(
      initUrl: json['initUrl'],
      currentUrl: json['currentUrl'],
      cookies: (json['cookies'] as List<dynamic>)
          .map((dynamic e) => cookieFromJson(e))
          .toList(),
      proxySettings: ProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
      userAgent: json['userAgent'],
      thirdPartyCookiesEnabled: json['thirdPartyCookiesEnabled'],
      stateSetterF: stateSetterF,
    );
  }
}
