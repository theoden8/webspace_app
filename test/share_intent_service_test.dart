import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/share_intent_service.dart';

const _channel = MethodChannel('org.codeberg.theoden8.webspace/share_intent');

/// The channel as `linux/my_application.cc` serves it: the URL the runner
/// was launched with, handed out once.
void _serveLikeLinux({required String? launchUrl}) {
  var pending = launchUrl;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'consumeLaunchUrl':
        final url = pending;
        pending = null;
        return url;
      case 'consumeLaunchHtml':
        return null;
    }
    throw MissingPluginException();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  // Host tests run on Linux, the platform whose cold-start link was dropped:
  // the Dart side never asked the runner for it (LIR-004).
  test('a desktop runner\'s launch link is read once', () async {
    _serveLikeLinux(
      launchUrl: 'webspace://open?url=https%3A%2F%2Fdiscord.com%2Fapp',
    );
    expect(
      await ShareIntentService.consumeLaunchUrl(),
      'webspace://open?url=https%3A%2F%2Fdiscord.com%2Fapp',
    );
    expect(await ShareIntentService.consumeLaunchUrl(), isNull);
    expect(await ShareIntentService.consumeLaunchHtml(), isNull);
  });

  test('a runner that serves no channel has nothing pending', () async {
    expect(await ShareIntentService.consumeLaunchUrl(), isNull);
    expect(await ShareIntentService.consumeLaunchHtml(), isNull);
  });
}
