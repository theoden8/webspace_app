import 'package:webview_flutter/webview_flutter.dart';

import 'settings/proxy.dart';

Map<String, dynamic> webViewCookieToJson(WebViewCookie cookie) => {
      'name': cookie.name,
      'value': cookie.value,
      'domain': cookie.domain,
      'path': cookie.path,
    };

WebViewCookie webViewCookieFromJson(Map<String, dynamic> json) => WebViewCookie(
      name: json['name'],
      value: json['value'],
      domain: json['domain'],
      path: json['path'],
    );

class WebViewModel {
  final String url;
  final List<WebViewCookie>? cookies;
  WebViewController? controller;
  ProxySettings proxySettings;
  bool javascriptEnabled;

  WebViewModel({required this.url, this.cookies, ProxySettings? proxySettings, this.javascriptEnabled=true,})
      : proxySettings = proxySettings ?? ProxySettings(type: ProxyType.DEFAULT);

  Future<void> loadCookies(WebViewController controller) async {
    if (cookies != null) {
      WebViewCookieManager cookieManager = WebViewCookieManager();
      for (WebViewCookie cookie in cookies!) {
        await cookieManager.setCookie(cookie);
      }
    }
  }

  WebViewController getController() {
    if (controller == null) {
      controller = WebViewController();
    }
    controller!.setJavaScriptMode(this.javascriptEnabled
               ? JavaScriptMode.unrestricted
               : JavaScriptMode.disabled);
    controller!.loadRequest(Uri.parse(this.url));
    return controller!;
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
    'url': url,
    'cookies': cookies?.map((cookie) => webViewCookieToJson(cookie)).toList(),
    'proxySettings': proxySettings.toJson(),
    'javascriptEnabled': javascriptEnabled,
  };

  factory WebViewModel.fromJson(Map<String, dynamic> json) {
    return WebViewModel(
      url: json['url'],
      cookies: (json['cookies'] as List<dynamic>?)
          ?.map((dynamic e) => webViewCookieFromJson(e as Map<String, dynamic>))
          .toList(),
      proxySettings: ProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
    );
  }
}
