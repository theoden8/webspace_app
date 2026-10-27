import 'package:flutter/foundation.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/popup_webview.dart' show PopupKind;
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/site_posture.dart';

/// What the host app answers for every webview that runs as a site, its own
/// and a nested screen alike. Built once by the host and passed whole, so a
/// surface, or a path that builds one early, cannot leave a prompt out.
final class WebViewHostHooks {
  const WebViewHostHooks({
    required this.isolation,
    required this.globalUserScripts,
    required this.save,
    required this.rebuild,
    required this.launchNested,
    required this.openInBrowser,
    required this.openSiteSettings,
    required this.showPopup,
    required this.externalScheme,
    required this.confirmScriptFetch,
    required this.untrustedCertificate,
    required this.httpAuth,
    required this.media,
  });

  /// How the sites' cookies are kept apart, and the jars that go with it;
  /// read when a webview is built, which is after the restore decides it.
  final Isolation Function() isolation;

  /// Takes [blocked] out of the jar of [controller]'s webview after a load
  /// (ISO-011, CONT-006). A delete the jar refuses leaves that cookie for the
  /// next load to take, and the rest still go.
  Future<void> removeBlockedCookies(
    List<Cookie> blocked, {
    required WebViewController? controller,
    required Uri url,
  }) async {
    final jar = isolation();
    for (final c in blocked) {
      try {
        await jar.deleteCookie(c, url: url, controller: controller);
      } on CookieJarFailure catch (e) {
        LogTag.cookieManager.warning(
            'Blocked cookie ${c.name} left for the next load: $e',
            sensitive: true);
      }
    }
  }

  /// The app-wide user scripts a site may opt into, read when a webview is
  /// built.
  final List<UserScriptConfig> Function() globalUserScripts;
  final Future<void> Function() save;
  final VoidCallback rebuild;

  final LaunchUrlFunc launchNested;

  /// Hands [url] to the system browser, the external-link mode's way out
  /// (NESTED-009).
  final Future<bool> Function(String url) openInBrowser;

  final void Function(SiteId siteId) openSiteSettings;
  /// Shows the popup window [windowId] a page asked for, as [kind] decided.
  final Future<void> Function(int windowId,
      {required String url, required PopupKind kind}) showPopup;

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
        isolation: isolation,
        globalUserScripts: globalUserScripts,
        save: save,
        rebuild: rebuild,
        launchNested: (_, {required posture, homeTitle}) {},
        openInBrowser: (_) async => false,
        openSiteSettings: (_) {},
        showPopup: (_, {required url, required kind}) async {},
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
