import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';

/// What the host app answers for every webview that runs as a site, its own
/// and a nested screen alike. Built once by the host and passed whole, so a
/// surface, or a path that builds one early, cannot leave a prompt out.
final class WebViewHostHooks {
  const WebViewHostHooks({
    required this.cookieManager,
    required this.containerCookieManager,
    required this.globalUserScripts,
    required this.save,
    required this.rebuild,
    required this.onScreen,
    required this.launchNested,
    required this.openInBrowser,
    required this.routeOutbound,
    required this.linkMenu,
    required this.openSiteSettings,
    required this.showPopup,
    required this.externalScheme,
    required this.confirmScriptFetch,
    required this.untrustedCertificate,
    required this.httpAuth,
    required this.media,
  });

  /// The engine's cookie readers: [containerCookieManager] under the
  /// container engine, [cookieManager] (the shared jar) otherwise.
  final CookieManager cookieManager;
  final ContainerCookieManager? containerCookieManager;

  /// The app-wide user scripts a site may opt into, read when a webview is
  /// built.
  final List<UserScriptConfig> Function() globalUserScripts;
  final Future<void> Function() save;
  final VoidCallback rebuild;

  /// Whether [slot] is the site on screen: a background site opens nothing
  /// nested and gets no device capture (MIC-014).
  final bool Function(WebViewModel slot) onScreen;
  final LaunchUrlFunc launchNested;

  /// Hands [url] to the system browser, the external-link mode's way out
  /// (NESTED-009).
  final Future<bool> Function(String url) openInBrowser;

  /// [source]'s webview is about to nest, send out or block [url]: true when
  /// the host took the link over (LIR-014, NESTED-009).
  final bool Function(WebViewModel source,
      {required String url,
      required NavigationDecision decision,
      required bool hadGesture}) routeOutbound;

  /// A long-press on a link in [source]'s webview (TAB-006).
  final void Function(WebViewModel source, {required String url}) linkMenu;
  final void Function(String siteId) openSiteSettings;
  final Future<void> Function(int windowId, {required String url}) showPopup;

  /// Confirms and launches a URL no webview renders (`intent://`, `tel:`),
  /// loading its web fallback into [loadIn] when it has one.
  final Future<void> Function(ExternalUrlInfo info,
      {required WebViewController? loadIn}) externalScheme;
  final Future<bool> Function(String url) confirmScriptFetch;
  final Future<bool> Function(String host,
      {required int port,
      required inapp.SslCertificate? certificate}) untrustedCertificate;
  final HttpAuthPrompt httpAuth;

  /// The capture and protected-content popups behind every [GrantStore].
  final MediaPrompter media;

  /// These answers for a webview no one is looking at, a background wake's
  /// headless check (NOTIF-016): it opens nothing, and every question the
  /// host would put to the user is declined.
  WebViewHostHooks unattended() => WebViewHostHooks(
        cookieManager: cookieManager,
        containerCookieManager: containerCookieManager,
        globalUserScripts: globalUserScripts,
        save: save,
        rebuild: rebuild,
        onScreen: (_) => false,
        launchNested: (_, {required posture, homeTitle}) {},
        openInBrowser: (_) async => false,
        routeOutbound:
            (_, {required url, required decision, required hadGesture}) => true,
        linkMenu: (_, {required url}) {},
        openSiteSettings: (_) {},
        showPopup: (_, {required url}) async {},
        externalScheme: (_, {required loadIn}) async {},
        confirmScriptFetch: (_) async => false,
        untrustedCertificate:
            (_, {required port, required certificate}) async => false,
        httpAuth: (_) async => null,
        media: const _Declines(),
      );
}

final class _Declines implements MediaPrompter {
  const _Declines();

  @override
  Future<CaptureGrant> capture(
    CaptureKind kind, {
    required String origin,
    required CaptureMode current,
  }) async =>
      (mode: kind.ask, source: null);

  @override
  Future<bool> protectedContent(String origin) async => false;
}
