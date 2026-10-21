import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// The Safari version claimed when the installed Safari cannot be read.
/// Bump it with each Safari major.
const String kFallbackSafariVersion = '26.0';

final RegExp _safariVersionShape = RegExp(r'^\d+(?:\.\d+){0,2}$');

/// The Mac's Safari user agent at [version]. Safari freezes the OS token at
/// `10_15_7` and WebKit at `605.1.15`; only `Version/` moves.
String buildMacSafariUserAgent(String version) =>
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/$version Safari/605.1.15';

/// The Mac's Safari user agent at the installed [safariVersion], or at
/// [kFallbackSafariVersion] when that could not be read.
String macSafariUserAgent({required String? safariVersion}) =>
    buildMacSafariUserAgent(
        safariVersion != null && _safariVersionShape.hasMatch(safariVersion)
            ? safariVersion
            : kFallbackSafariVersion);

/// The user agent a webview is built with: the site's [override], or the
/// host's default.
String? webViewUserAgent(String? override) =>
    override ?? HostBrowser.defaultUserAgent;

/// What a site's webview sends as its user agent when the user set none
/// (UAID-005), resolved by [initialize] before the first webview is built.
///
/// macOS WKWebView stops its user agent at `(KHTML, like Gecko)`, where
/// Safari, the same engine, goes on with `Version/<v> Safari/605.1.15`, and
/// sites that read the user agent take a string without it for Chrome. The
/// page's navigator already is Safari's, so no shim is needed. Everywhere else
/// the webview's own user agent already names its browser, and this is null.
abstract final class HostBrowser {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/host_browser');

  static String? _defaultUserAgent;
  static String? get defaultUserAgent => _defaultUserAgent;

  static ({String? agent})? _engine;

  /// What a site's webview sends as its user agent when the user set none:
  /// [defaultUserAgent], else the engine's own, read once where its plugin
  /// reports it (Android, iOS). Null elsewhere: Linux WPE does not say, and a
  /// browser sets its own.
  static Future<String?> sentUserAgent() async {
    final own = _defaultUserAgent;
    if (own != null || !(hostIsAndroid || hostIsIOS)) return own;
    if (_engine case (:final agent)) return agent;
    String? agent;
    try {
      agent = await inapp.InAppWebViewController.getDefaultUserAgent();
    } on PlatformException catch (e) {
      LogTag.startup.debug('engine user agent unread: $e');
    } on MissingPluginException catch (e) {
      LogTag.startup.debug('engine user agent unread: $e');
    }
    _engine = (agent: agent);
    return agent;
  }

  @visibleForTesting
  static set defaultUserAgentForTest(String? value) =>
      _defaultUserAgent = value;

  static Future<void> initialize() async {
    if (!hostIsMacOS) return;
    String? safariVersion;
    try {
      safariVersion = await _channel.invokeMethod<String>('safariVersion');
    } on MissingPluginException {
      safariVersion = null;
    } on PlatformException {
      safariVersion = null;
    }
    _defaultUserAgent = macSafariUserAgent(safariVersion: safariVersion);
    LogTag.startup
        .debug('host user agent: Safari ${safariVersion ?? 'unread'}');
  }
}
