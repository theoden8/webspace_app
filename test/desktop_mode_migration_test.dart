import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/web_view_model.dart';

/// Regression tests for migration of legacy `desktopMode` field on backup
/// import. The toggle existed in earlier branches (both as a `bool` and
/// as a string-enum picker `linux`/`macos`/`windows`/`off`); the current
/// design infers desktop mode from the per-site UA. Migration policy:
/// when the legacy field said "desktop on" but the user had no custom UA,
/// populate the UA with a Firefox desktop UA matching their platform. If
/// they already had a custom UA, that wins (their explicit choice is
/// preserved).
void main() {
  Map<String, dynamic> baseJson({
    Object? desktopMode,
    String userAgent = '',
  }) {
    return {
      'initUrl': 'https://example.com',
      'currentUrl': 'https://example.com',
      'cookies': <dynamic>[],
      'proxySettings': {'type': 0, 'address': null},
      'javascriptEnabled': true,
      'userAgent': userAgent,
      'thirdPartyCookiesEnabled': false,
      if (desktopMode != null) 'desktopMode': desktopMode,
    };
  }

  group('WebViewModel.fromJson legacy desktopMode migration', () {
    test('legacy bool true with empty UA → Firefox Linux desktop UA', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: true),
        null,
      );
      expect(model.userAgent, equals(firefoxLinuxDesktopUserAgent));
      expect(isDesktopUserAgent(model.userAgent), isTrue);
    });

    test('legacy bool false with empty UA → empty UA (mobile default)', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: false),
        null,
      );
      expect(model.userAgent, equals(''));
      expect(isDesktopUserAgent(model.userAgent), isFalse);
    });

    test('legacy string "linux" → Firefox Linux UA', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'linux'),
        null,
      );
      expect(model.userAgent, equals(firefoxLinuxDesktopUserAgent));
    });

    test('legacy string "macos" → Firefox macOS UA', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'macos'),
        null,
      );
      expect(model.userAgent, equals(firefoxMacosDesktopUserAgent));
    });

    test('legacy string "windows" → Firefox Windows UA', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'windows'),
        null,
      );
      expect(model.userAgent, equals(firefoxWindowsDesktopUserAgent));
    });

    test('legacy string "off" → empty UA', () {
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'off'),
        null,
      );
      expect(model.userAgent, equals(''));
    });

    test('user-set custom UA wins over legacy desktopMode', () {
      // The user explicitly typed a custom UA. Legacy desktopMode = "macos"
      // would migrate to the macOS Firefox UA, but only when the user
      // had nothing of their own. Their custom UA is the explicit
      // choice and must be preserved.
      const custom = 'MyCustomBot/2.0';
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'macos', userAgent: custom),
        null,
      );
      expect(model.userAgent, equals(custom));
    });

    test('absent desktopMode field → empty UA', () {
      final model = WebViewModel.fromJson(baseJson(), null);
      expect(model.userAgent, equals(''));
    });

    test('unknown desktopMode value → empty UA (no crash)', () {
      // Defensive: a future format we don't recognize shouldn't crash
      // import. Treat as unknown / no migration.
      final model = WebViewModel.fromJson(
        baseJson(desktopMode: 'plan9'),
        null,
      );
      expect(model.userAgent, equals(''));
    });
  });
}
