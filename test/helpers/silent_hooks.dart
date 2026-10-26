import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_host_hooks.dart';

import 'capture_fakes.dart';

/// A host that answers nothing, for a webview whose test never reaches a
/// prompt.
WebViewHostHooks silentHooks() => WebViewHostHooks(
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
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );
