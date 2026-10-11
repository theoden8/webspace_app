// UAID-005: a site with no user agent of its own sends the browser of the OS
// the app runs on.

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_preset.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

const _safari =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/26.0.1 Safari/605.1.15';

String? _postureUserAgent(WebViewModel m) =>
    m.sitePosture(globalUserScripts: const <UserScriptConfig>[]).page.userAgent;

void main() {
  tearDown(() => HostBrowser.userAgentForTest = const WebViewOwnUserAgent());

  group('hostUserAgentFor', () {
    test('a Mac app completes the webview UA with Safari\'s', () {
      final host =
          hostUserAgentFor(host: AppHost.mac, safariVersion: '26.0.1');
      expect(host, isA<SafariCompletion>());
      expect(host.completion, _safari);
      expect(host.claim, isNull);
      expect(host.defaultUserAgent, _safari);
    });

    test('the iOS build on a Mac claims the Mac\'s Safari', () {
      final host = hostUserAgentFor(
          host: AppHost.iosAppOnMac, safariVersion: '26.0.1');
      expect(host, isA<MacSafariClaim>());
      expect(host.claim, _safari);
      expect(host.completion, isNull);
      expect(host.defaultUserAgent, _safari);
    });

    test('elsewhere the webview\'s own UA is left alone', () {
      final host = hostUserAgentFor(host: AppHost.other, safariVersion: null);
      expect(host, isA<WebViewOwnUserAgent>());
      expect(host.claim, isNull);
      expect(host.completion, isNull);
      expect(host.defaultUserAgent, isNull);
    });

    for (final unread in [null, '', 'Safari', '26.0 beta', '1.2.3.4']) {
      test('an unreadable Safari version ($unread) falls back', () {
        expect(
          hostUserAgentFor(host: AppHost.mac, safariVersion: unread)
              .completion,
          buildMacSafariUserAgent(kFallbackSafariVersion),
        );
      });
    }
  });

  group('the Mac Safari UA', () {
    test('is a desktop WebKit UA on macOS', () {
      expect(inferUaEngine(_safari), UaEngine.webkit);
      expect(isDesktopUserAgent(_safari), isTrue);
      expect(inferDesktopUaPlatform(_safari), DesktopUaPlatform.macos);
    });

    test('carries the "<version> Safari" pair UA sniffers read', () {
      expect(RegExp(r'\d+\.\d+(?:\.\d+)? Safari/').hasMatch(_safari), isTrue);
    });

    test('is neither a generated preset nor a stock webview default', () {
      expect(recognizeGeneratedUserAgent(_safari), isNull);
      expect(isStockWebViewDefaultUserAgent(_safari), isFalse);
    });
  });

  group('a site with no user agent', () {
    test('claims the Mac Safari UA in the iOS build on a Mac', () {
      HostBrowser.userAgentForTest = const MacSafariClaim(_safari);
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(_postureUserAgent(m), _safari);
      expect(m.effectiveUserAgent, isEmpty,
          reason: 'the settings field shows no override');
    });

    test('claims nothing on a Mac app: its navigator already is Safari\'s',
        () {
      HostBrowser.userAgentForTest = const SafariCompletion(_safari);
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(_postureUserAgent(m), isNull);
      expect(webViewUserAgent(_postureUserAgent(m)), _safari);
    });

    test('a user agent the user set wins over the host\'s', () {
      HostBrowser.userAgentForTest = const MacSafariClaim(_safari);
      final m = WebViewModel(
          initUrl: 'https://example.com', userAgent: 'Custom/1.0');
      expect(_postureUserAgent(m), 'Custom/1.0');
      HostBrowser.userAgentForTest = const SafariCompletion(_safari);
      expect(webViewUserAgent(_postureUserAgent(m)), 'Custom/1.0');
    });
  });

  test('a settings update keeps the completed UA the webview was built with',
      () {
    HostBrowser.userAgentForTest = const SafariCompletion(_safari);
    final settings = inapp.InAppWebViewSettings()
      ..userAgent = webViewUserAgent(null);
    applyWebViewOptions(settings, javascriptEnabled: true, userAgent: null);
    expect(settings.userAgent, _safari);
  });
}
