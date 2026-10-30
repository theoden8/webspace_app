import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_posture.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/isolations.dart';

WebViewModel _site({required bool tp, bool? own}) => WebViewModel(
      initUrl: 'https://bank.example',
      trackingProtectionEnabled: tp,
      lockdownModeEnabled: own,
    );

SitePosture _posture(WebViewModel m) => m.sitePosture(
    globalUserScripts: const <UserScriptConfig>[], isolation: fakeContainers());

/// What the native side is told for [m], as the site's webview, its popups
/// and its background checks are all built.
bool? _native(WebViewModel m) => WebViewFactory.siteSettings(
      (
        containerId: null,
        proxy: null,
        proxyUnavailable: false,
        proxyConfigured: false,
        relayDown: false,
        releasesContainerProxy: false,
      ),
      posture: _posture(m),
      textZoom: 100,
      desktopMode: false,
    ).lockdownModeEnabled;

void main() {
  group('Lockdown Mode follows Tracking Protection (ETP-032)', () {
    test('a following site runs it while Tracking Protection is on', () {
      final m = _site(tp: true);
      expect(m.effectiveLockdownModeEnabled, isTrue);
      expect(_posture(m).page.lockdownMode, isTrue);
      expect(_native(m), isTrue);
      expect(_native(_site(tp: false)), isNull);
    });

    test("the site's own choice wins over Tracking Protection either way", () {
      expect(_native(_site(tp: true, own: false)), isNull);
      expect(_native(_site(tp: false, own: true)), isTrue);
    });

    test('off is null natively, never false: the device keeps its own mode',
        () {
      expect(_native(_site(tp: false, own: false)), isNull);
    });

    test('a nested screen runs it as the opening site does', () {
      final p = _posture(_site(tp: true)).forNested();
      expect(p.page.lockdownMode, isTrue);
    });

    test('saved only when set, so a following site saves the same bytes', () {
      final key = SiteField.lockdownModeEnabled.key;
      WebViewModel read(Map<String, dynamic> json) =>
          WebViewModel.fromJson(json, stateSetterF: null);
      final following = _site(tp: true).toJson();
      expect(following.containsKey(key), isFalse);
      expect(read(following).lockdownModeEnabled, isNull);
      for (final own in [false, true]) {
        final json = _site(tp: true, own: own).toJson();
        expect(json[key], own);
        expect(read(json).lockdownModeEnabled, own);
      }
    });

    test('a wrong-typed value reads as following', () {
      final json = _site(tp: false).toJson()
        ..[SiteField.lockdownModeEnabled.key] = 'yes';
      expect(
          WebViewModel.fromJson(json, stateSetterF: null).lockdownModeEnabled,
          isNull);
    });
  });
}
