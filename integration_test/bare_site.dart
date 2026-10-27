import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_hooks.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/webview.dart';

/// How this run keeps sites' cookies apart, decided as the restore decides
/// by [bareSetUp], which every test that uses this harness runs first.
late final Isolation bareIsolation;

/// The page scripts, the default composition mode, the app-wide proxy as
/// stored, and [bareIsolation] probed on this device.
Future<void> bareSetUp() async {
  await PageJs.load();
  WebViewFactory.hybridComposition = true;
  await GlobalOutboundProxy.initialize();
  bareIsolation = await Isolation.probe(
    native: ContainerNative.instance,
    legacy: () => CookieIsolationEngine(
      cookieManager: CookieManager(),
      storage: CookieSecureStorage(),
    ),
  );
}

/// The posture of a site with every blocker and Tracking Protection off, so a
/// test measures only the path it is about. Built by the app's own resolver,
/// so it is a posture a real site can have; [adjust] sets anything else.
SitePosture barePosture(
  String url, {
  required SiteId siteId,
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
  return site.sitePosture(globalUserScripts: const [], isolation: bareIsolation);
}

/// A host with no app around the webview: every prompt answers no and nothing
/// opens elsewhere. [httpAuth] stands in for the sign-in prompt; [leaving]
/// hears each URL a navigation would have taken out of the site (a nested
/// screen, the browser, another site's slot), which this host declines.
WebViewHostHooks bareHooks({
  HttpAuthPrompt? httpAuth,
  void Function(String url)? leaving,
}) =>
    WebViewHostHooks(
      isolation: () => bareIsolation,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      launchNested: (url, {required posture, homeTitle}) => leaving?.call(url),
      openInBrowser: (url) async {
        leaving?.call(url);
        return false;
      },
      openSiteSettings: (_) {},
      showPopup: (_, {required url, required kind}) async {},
      externalScheme: (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      httpAuth: httpAuth ?? (_) async => null,
      media: _NoPrompts(),
    );

/// [bareHooks] for a site's own webview, which is on screen and takes no
/// link to another site's slot ([leaving] hears it).
SiteHooks bareSiteHooks({void Function(String url)? leaving}) => SiteHooks(
      host: bareHooks(leaving: leaving),
      onScreen: (_) => true,
      routeOutbound: (_, {required url, required decision, required hadGesture}) {
        leaving?.call(url);
        return false;
      },
      linkMenu: (_, {required url}) async {},
      firstPageLoaded: (_, {required url}) async {},
    );

/// A capture prompt in these tests is a bug in the test.
class _NoPrompts implements MediaPrompter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no capture prompt expected: ${invocation.memberName}');
}
