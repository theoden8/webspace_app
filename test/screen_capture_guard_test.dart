import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/screen_capture_guard.dart';

const _channel = MethodChannel('test/screen_capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<bool> sent;
  PlatformException? failNext;

  setUp(() {
    sent = [];
    failNext = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'setBlocked');
      sent.add((call.arguments as Map)['blocked'] as bool);
      final failure = failNext;
      failNext = null;
      if (failure != null) throw failure;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('screenCaptureBlocked (SCREENBLOCK-002)', () {
    test('the app-wide switch blocks whatever is on screen', () {
      expect(screenCaptureBlocked(appWide: true, siteOnScreen: null), isTrue);
      expect(screenCaptureBlocked(appWide: true, siteOnScreen: false), isTrue);
      expect(screenCaptureBlocked(appWide: true, siteOnScreen: true), isTrue);
    });

    test('a site blocks only while it is on screen', () {
      expect(screenCaptureBlocked(appWide: false, siteOnScreen: true), isTrue);
      expect(
          screenCaptureBlocked(appWide: false, siteOnScreen: false), isFalse);
      expect(screenCaptureBlocked(appWide: false, siteOnScreen: null), isFalse);
    });
  });

  group('ScreenCaptureGuard', () {
    test('sends a value only when it changes', () async {
      final guard = ScreenCaptureGuard(supported: true, channel: _channel);
      await guard.apply(false);
      await guard.apply(false);
      await guard.apply(true);
      await guard.apply(true);
      await guard.apply(false);
      expect(sent, [false, true, false]);
    });

    test('sends nothing where the platform has no block', () async {
      final guard = ScreenCaptureGuard(supported: false, channel: _channel);
      await guard.apply(true);
      expect(sent, isEmpty);
    });

    test('a failed call is sent again on the next apply', () async {
      final guard = ScreenCaptureGuard(supported: true, channel: _channel);
      failNext = PlatformException(code: 'boom');
      await guard.apply(true);
      await guard.apply(true);
      await guard.apply(true);
      expect(sent, [true, true]);
    });
  });
}
