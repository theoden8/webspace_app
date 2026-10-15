import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_inappwebview_macos/flutter_inappwebview_macos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/cookie_manager.dart';

/// What the plugin's cookie channel throws reaches a caller of the shared
/// jar as one type, [CookieJarFailure], whichever way the channel failed: an
/// error envelope from the native side, or no handler in this engine
/// (ISO-014). Each caller answers that type; nothing else gets through.
void main() {
  const channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_cookiemanager');
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    // The wrapper reads the whole jar in one call on an Apple host and per
    // URL elsewhere, so the platform under it is the one the host's path
    // calls: Android's has no getAllCookies.
    if (hostIsMacOS) {
      MacOSInAppWebViewPlatform.registerWith();
    } else {
      AndroidInAppWebViewPlatform.registerWith();
    }
    messenger =
        TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final url = Uri.parse('https://example.com/');
  final calls = <String, Future<void> Function(CookieManager jar)>{
    'getCookies': (jar) => jar.getCookies(url: url),
    'getAllCookies': (jar) => jar.getAllCookies(candidateUrls: [url]),
    'setCookie': (jar) => jar.setCookie(url: url, name: 'n', value: 'v'),
    'deleteCookie': (jar) => jar.deleteCookie(url: url, name: 'n'),
    'deleteAllCookiesForUrl': (jar) => jar.deleteAllCookiesForUrl(url),
    'deleteAllCookies': (jar) => jar.deleteAllCookies(),
  };

  for (final MapEntry(key: name, value: call) in calls.entries) {
    test('ISO-014: $name fails as CookieJarFailure on an error envelope',
        () async {
      messenger.setMockMethodCallHandler(
          channel, (_) async => throw PlatformException(code: 'refused'));
      await expectLater(
          call(CookieManager()), throwsA(isA<CookieJarFailure>()));
    });

    test('ISO-014: $name fails as CookieJarFailure with no handler',
        () async {
      await expectLater(
          call(CookieManager()), throwsA(isA<CookieJarFailure>()));
    });
  }
}
