import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/lockdown_mode_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('org.codeberg.theoden8.webspace/lockdown_mode');

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => handler(call));
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    LockdownModeService.instance.debugIsIOS = null;
  });

  test('returns false off-iOS without touching the channel', () async {
    var invoked = false;
    mockChannel((call) async {
      invoked = true;
      return true;
    });
    LockdownModeService.instance.debugIsIOS = false;
    expect(await LockdownModeService.instance.isLockdownModeEnabled(), isFalse);
    expect(invoked, isFalse);
  });

  test('reports lockdown enabled from the native probe', () async {
    mockChannel((call) async {
      expect(call.method, 'isLockdownModeEnabled');
      return true;
    });
    LockdownModeService.instance.debugIsIOS = true;
    expect(await LockdownModeService.instance.isLockdownModeEnabled(), isTrue);
  });

  test('reports lockdown disabled from the native probe', () async {
    mockChannel((call) async => false);
    LockdownModeService.instance.debugIsIOS = true;
    expect(await LockdownModeService.instance.isLockdownModeEnabled(), isFalse);
  });

  test('a channel error is non-fatal and reads as not-enabled', () async {
    mockChannel((call) async => throw PlatformException(code: 'nope'));
    LockdownModeService.instance.debugIsIOS = true;
    expect(await LockdownModeService.instance.isLockdownModeEnabled(), isFalse);
  });
}
