import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

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
    required this.routeOutbound,
    required this.linkMenu,
    required this.openSiteSettings,
    required this.showPopup,
    required this.externalScheme,
    required this.confirmScriptFetch,
    required this.untrustedCertificate,
    required this.httpAuth,
    required this.protectedMedia,
    required this.camera,
    required this.microphone,
    required this.screenShare,
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

  /// [source]'s webview is about to nest, send out or block [url]: true when
  /// the host took the link over (LIR-014, NESTED-009).
  final bool Function(WebViewModel source, String url,
      NavigationDecision decision, bool hadGesture) routeOutbound;

  /// A long-press on a link in [source]'s webview (TAB-006).
  final void Function(WebViewModel source, String url) linkMenu;
  final void Function(String siteId) openSiteSettings;
  final Future<void> Function(int windowId, String url) showPopup;

  /// Confirms and launches a URL no webview renders (`intent://`, `tel:`),
  /// loading its web fallback into [loadIn] when it has one.
  final Future<void> Function(ExternalUrlInfo info, WebViewController? loadIn)
      externalScheme;
  final Future<bool> Function(String url) confirmScriptFetch;
  final Future<bool> Function(
      String host, int port, inapp.SslCertificate? certificate) untrustedCertificate;
  final HttpAuthPrompt httpAuth;
  final Future<bool> Function(String origin) protectedMedia;
  final Future<CameraDecision> Function(
      String origin, CameraAccessMode current) camera;
  final Future<MicrophoneDecision> Function(
      String origin, MicrophoneAccessMode current) microphone;
  final Future<ScreenShareDecision> Function(
      String origin, ScreenShareMode current) screenShare;
}
