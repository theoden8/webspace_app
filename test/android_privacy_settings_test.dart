import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/isolations.dart';

/// What the native side is told for a site, as its webview, its popups and
/// its background checks are all built.
inapp.InAppWebViewSettings _native({required bool tp}) =>
    WebViewFactory.siteSettings(
      (
        containerId: null,
        proxy: null,
        proxyUnavailable: false,
        proxyConfigured: false,
        relayDown: false,
        releasesContainerProxy: false,
      ),
      posture: WebViewModel(
        initUrl: 'https://bank.example',
        trackingProtectionEnabled: tp,
      ).sitePosture(
        globalUserScripts: const <UserScriptConfig>[],
        isolation: fakeContainers(),
      ),
      textZoom: 100,
      desktopMode: false,
    );

void main() {
  test(
      'ETP-019: Tracking Protection turns on the Android privacy settings, '
      'and off leaves each at its native default', () {
    final on = _native(tp: true);
    expect(on.requestedWithHeaderOriginAllowList, isEmpty);
    expect(on.attributionRegistrationBehavior,
        inapp.AttributionBehavior.DISABLED);
    expect(on.webViewMediaIntegrityApiStatus,
        inapp.WebViewMediaIntegrityApiStatus.ENABLED_WITHOUT_APP_IDENTITY,
        reason: 'the integrity token stays for anti-fraud, without the '
            "app's identity");

    final off = _native(tp: false);
    expect(off.requestedWithHeaderOriginAllowList, isNull);
    expect(off.attributionRegistrationBehavior, isNull);
    expect(off.webViewMediaIntegrityApiStatus, isNull);
  });
}
