import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

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
      launchNested: (_, _, {homeTitle}) {},
      openInBrowser: (_) async => false,
      routeOutbound: (_, _, _, _) => false,
      linkMenu: (_, _) {},
      openSiteSettings: (_) {},
      showPopup: (_, _) async {},
      externalScheme: (_, _) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, _, _) async => false,
      httpAuth: httpAuth ?? (_) async => null,
      media: _NoPrompts(),
    );

/// A capture prompt in these tests is a bug in the test.
class _NoPrompts implements MediaPrompter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no capture prompt expected: ${invocation.memberName}');
}
