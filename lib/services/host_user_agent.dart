import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// Where the app runs, as far as the user agent is concerned.
enum AppHost { mac, iosAppOnMac, other }

/// What a site's webview sends as its user agent when the user set none
/// (UAID-005): the browser of the OS the app runs on.
sealed class HostUserAgent {
  const HostUserAgent();

  /// The user agent a site claims in place of an override, handled like a
  /// desktop user agent the user picked: desktop mode and identity shims.
  String? get claim => switch (this) {
        WebViewOwnUserAgent() || SafariCompletion() => null,
        MacSafariClaim(:final userAgent) => userAgent,
      };

  /// The user agent the webview is built with for a site that claims none.
  String? get completion => switch (this) {
        WebViewOwnUserAgent() || MacSafariClaim() => null,
        SafariCompletion(:final userAgent) => userAgent,
      };

  /// What a site with no override sends; null when it is the webview's own.
  String? get defaultUserAgent => claim ?? completion;
}

/// The webview's own user agent already names its browser: Android System
/// WebView, WPE WebKit, iOS WebKit on an iPhone or iPad.
final class WebViewOwnUserAgent extends HostUserAgent {
  const WebViewOwnUserAgent();
}

/// macOS WKWebView stops its user agent at `(KHTML, like Gecko)`, where
/// Safari, the same engine, goes on with `Version/<v> Safari/605.1.15`, and
/// sites that read the user agent take a string without it for Chrome. The
/// page's navigator already is Safari's, so no shim is needed.
final class SafariCompletion extends HostUserAgent {
  const SafariCompletion(this.userAgent);
  final String userAgent;
}

/// The iOS build running on a Mac: its WebKit reports an iPhone or iPad
/// while the app runs on a Mac, so the site claims the Mac's Safari.
final class MacSafariClaim extends HostUserAgent {
  const MacSafariClaim(this.userAgent);
  final String userAgent;
}

/// The [HostUserAgent] for [host], at the installed [safariVersion] when it
/// was readable.
HostUserAgent hostUserAgentFor({
  required AppHost host,
  required String? safariVersion,
}) {
  final version = safariVersion != null &&
          _safariVersionShape.hasMatch(safariVersion)
      ? safariVersion
      : kFallbackSafariVersion;
  return switch (host) {
    AppHost.mac => SafariCompletion(buildMacSafariUserAgent(version)),
    AppHost.iosAppOnMac => MacSafariClaim(buildMacSafariUserAgent(version)),
    AppHost.other => const WebViewOwnUserAgent(),
  };
}

/// The user agent a webview is built with: the site's [claimed] one, or the
/// host's completion of the webview's own.
String? webViewUserAgent(String? claimed) =>
    claimed ?? HostBrowser.userAgent.completion;

/// The host's [HostUserAgent], resolved by [initialize] before the first
/// webview is built.
abstract final class HostBrowser {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/host_browser');

  static HostUserAgent _userAgent = const WebViewOwnUserAgent();
  static HostUserAgent get userAgent => _userAgent;

  @visibleForTesting
  static set userAgentForTest(HostUserAgent value) => _userAgent = value;

  static Future<void> initialize() async {
    if (!hostIsIOS && !hostIsMacOS) return;
    Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<Object?, Object?>('describe');
    } on MissingPluginException {
      reply = null;
    } on PlatformException {
      reply = null;
    }
    final host = hostIsMacOS
        ? AppHost.mac
        : reply?['iosAppOnMac'] == true
            ? AppHost.iosAppOnMac
            : AppHost.other;
    final safariVersion = switch (reply?['safariVersion']) {
      final String v => v,
      _ => null,
    };
    _userAgent = hostUserAgentFor(host: host, safariVersion: safariVersion);
    LogTag.startup.debug(
        'host user agent: ${host.name}, Safari ${safariVersion ?? 'unread'}');
  }
}
