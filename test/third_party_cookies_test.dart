import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/isolations.dart';

WebViewModel _site({required bool own, bool tp = false}) => WebViewModel(
      initUrl: 'https://captcha.example',
      thirdPartyCookiesEnabled: own,
      trackingProtectionEnabled: tp,
    );

SitePosture _posture(WebViewModel m) => m.sitePosture(
    globalUserScripts: const <UserScriptConfig>[], isolation: fakeContainers());

/// What the native side is told for [posture], as the site's webview, its
/// popups and its background checks are all built.
bool? _native(SitePosture posture) => WebViewFactory.siteSettings(
      (
        containerId: null,
        proxy: null,
        proxyUnavailable: false,
        proxyConfigured: false,
        relayDown: false,
        releasesContainerProxy: false,
      ),
      posture: posture,
      textZoom: 100,
      desktopMode: false,
    ).thirdPartyCookiesEnabled;

void main() {
  group("a site's third-party cookies reach its webview (CAPTCHA-006)", () {
    test('on where the site turned them on, off where it did not', () {
      expect(_native(_posture(_site(own: true))), isTrue);
      expect(_native(_posture(_site(own: false))), isFalse);
    });

    test('a nested screen runs them as the opening site does', () {
      expect(_native(_posture(_site(own: true)).forNested()), isTrue);
      expect(_native(_posture(_site(own: false)).forNested()), isFalse);
    });

    test('Tracking Protection forces them off whatever the site chose '
        '(ETP-024)', () {
      expect(_native(_posture(_site(own: true, tp: true))), isFalse);
    });
  });
}
