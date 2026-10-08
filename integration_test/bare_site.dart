import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// The posture of a site with every blocker and Tracking Protection off, so a
/// test measures only the path it is about. Built by the app's own resolver,
/// so it is a posture a real site can have; [adjust] sets anything else.
SitePosture barePosture(
  String url, {
  required String siteId,
  UserProxySettings? proxy,
  void Function(WebViewModel site)? adjust,
}) {
  final site = WebViewModel(
    initUrl: url,
    siteId: siteId,
    proxySettings: proxy,
    clearUrlEnabled: false,
    dnsBlockEnabled: false,
    contentBlockEnabled: false,
    trackingProtectionEnabled: false,
  );
  adjust?.call(site);
  return site.sitePosture(globalUserScripts: const []);
}

/// A host with no app around the webview: every prompt answers no and nothing
/// opens elsewhere. [httpAuth] stands in for the sign-in prompt.
WebViewHostHooks bareHooks({HttpAuthPrompt? httpAuth}) => WebViewHostHooks(
      cookieManager: CookieManager(),
      containerCookieManager: null,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      onScreen: (_) => true,
      launchNested: (_, {required posture, homeTitle}) {},
      openInBrowser: (_) async => false,
      routeOutbound:
          (_, {required url, required decision, required hadGesture}) => false,
      linkMenu: (_, {required url}) {},
      openSiteSettings: (_) {},
      showPopup: (_, {required url}) async {},
      externalScheme: (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      httpAuth: httpAuth ?? (_) async => null,
      media: _NoPrompts(),
    );

/// A capture prompt in these tests is a bug in the test.
class _NoPrompts implements MediaPrompter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no capture prompt expected: ${invocation.memberName}');
}
