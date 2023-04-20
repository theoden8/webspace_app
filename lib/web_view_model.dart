import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

import 'settings/proxy.dart';

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

Map<String, dynamic> cookieToJson(Cookie cookie) {
  return {
    'name': cookie.name,
    'value': cookie.value,
    'expires': cookie.expires?.toIso8601String(),
    'maxAge': cookie.maxAge,
    'domain': cookie.domain,
    'path': cookie.path,
    'secure': cookie.secure,
    'httpOnly': cookie.httpOnly,
  };
}

Cookie cookieFromJson(Map<String, dynamic> json) {
  Cookie cookie = Cookie(json['name'], json['value']);
  cookie.expires = json['expires'] != null ? DateTime.parse(json['expires']) : null;
  cookie.maxAge = json['maxAge'];
  cookie.domain = json['domain'];
  cookie.path = json['path'];
  cookie.secure = json['secure'];
  cookie.httpOnly = json['httpOnly'];
  return cookie;
}

class WebViewModel {
  String url;
  List<Cookie> cookies;
  WebViewController? controller;
  ProxySettings proxySettings;
  bool javascriptEnabled;
  String? userAgent;
  bool thirdPartyCookiesEnabled;

  WebViewModel({
    required this.url,
    this.cookies=const [],
    ProxySettings? proxySettings,
    this.javascriptEnabled=true,
    this.userAgent,
    this.thirdPartyCookiesEnabled=false,
  }):
    proxySettings = proxySettings ?? ProxySettings(type: ProxyType.DEFAULT);

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

    await controller.runJavaScript(script);
  }

  WebViewController getController(launchUrl, WebviewCookieManager cookieManager, savefunc) {
    if (controller == null) {
      controller = WebViewController();
    }
    controller!.setJavaScriptMode(this.javascriptEnabled
               ? JavaScriptMode.unrestricted
               : JavaScriptMode.disabled);
    controller!.loadRequest(Uri.parse(this.url));
    if (userAgent != null) {
      controller!.setUserAgent(userAgent!);
    }
    controller!.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (NavigationRequest request) async {
          String requestDomain = extractDomain(request.url);
          String initialDomain = extractDomain(this.url);

          // Extract top-level and second-level domains
          List<String> requestDomainParts = requestDomain.split('.');
          List<String> initialDomainParts = initialDomain.split('.');

          // Compare top-level and second-level domains
          bool sameTopLevelDomain = requestDomainParts.last == initialDomainParts.last;
          bool sameSecondLevelDomain = requestDomainParts[requestDomainParts.length - 2] ==
              initialDomainParts[initialDomainParts.length - 2];

          if (sameTopLevelDomain && sameSecondLevelDomain) {
            return NavigationDecision.navigate;
          } else {
            await launchUrl(request.url);
            return NavigationDecision.prevent;
          }
        },
        onPageFinished: (url) async {
          cookies = await cookieManager.getCookies(this.url);
          if(!thirdPartyCookiesEnabled) {
            removeThirdPartyCookies(controller!);
          }
          this.url = url;
          await savefunc();
        }
      ),
    );
    return controller!;
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
    'url': url,
    'cookies': cookies.map((cookie) => cookieToJson(cookie)).toList(),
    'proxySettings': proxySettings.toJson(),
    'javascriptEnabled': javascriptEnabled,
    'userAgent': userAgent,
    'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
  };

  factory WebViewModel.fromJson(Map<String, dynamic> json) {
    return WebViewModel(
      url: json['url'],
      cookies: (json['cookies'] as List<dynamic>)
          .map((dynamic e) => cookieFromJson(e as Map<String, dynamic>))
          .toList(),
      proxySettings: ProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
      userAgent: json['userAgent'],
      thirdPartyCookiesEnabled: json['thirdPartyCookiesEnabled'],
    );
  }
}
