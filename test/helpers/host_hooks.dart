import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/network_sign_in.dart';
import 'package:webspace/services/popup_webview.dart' show PopupKind;
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview_host_hooks.dart';

import 'capture_fakes.dart';
import 'isolations.dart';

/// A host that answers every webview prompt with no and does nothing else;
/// a test names only the answers it watches.
WebViewHostHooks inertHostHooks({
  Isolation Function() isolation = fakeSharedJar,
  Future<void> Function(int windowId,
          {required String url, required PopupKind kind})?
      showPopup,
  Future<void> Function(ExternalUrlInfo info,
          {required WebViewController? loadIn})?
      externalScheme,
  Future<bool> Function(String host,
          {required int port, required inapp.SslCertificate? certificate})?
      untrustedCertificate,
  Future<void> Function(SignInNotice notice)? networkSignIn,
}) =>
    WebViewHostHooks(
      isolation: isolation,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      launchNested: (_, {required posture, homeTitle}) {},
      openInBrowser: (_) async => false,
      openSiteSettings: (_) {},
      showPopup: showPopup ?? (_, {required url, required kind}) async {},
      externalScheme: externalScheme ?? (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: untrustedCertificate ??
          (_, {required port, required certificate}) async => false,
      networkSignIn: networkSignIn ?? (_) async {},
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );
