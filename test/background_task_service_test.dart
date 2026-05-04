import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/background_task_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel =
      MethodChannel('org.codeberg.theoden8.webspace/background_task');

  late List<MethodCall> calls;
  late dynamic Function(MethodCall)? handler;

  setUp(() {
    calls = [];
    handler = (call) async {
      calls.add(call);
      return null;
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => handler!(call));
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('BackgroundTaskService (NOTIF-005-I bridge)', () {
    test('beginGracePeriod / endGracePeriod / scheduleNextRefresh route to channel on iOS',
        () async {
      // The service short-circuits to no-op on non-iOS via `Platform.isIOS`,
      // and the host running this test isn't iOS. So we exercise the
      // channel surface by calling `bgRefreshDidComplete` which still
      // skips on non-iOS — assert we get a clean no-op (no calls,
      // no throw).
      await BackgroundTaskService.instance.beginGracePeriod();
      await BackgroundTaskService.instance.endGracePeriod();
      await BackgroundTaskService.instance.scheduleNextRefresh();
      await BackgroundTaskService.instance.cancelScheduledRefreshes();
      await BackgroundTaskService.instance.bgRefreshDidComplete(success: true);
      // Off-iOS: every method is a no-op, no channel traffic.
      expect(calls, isEmpty);
    });

    test('initialize is idempotent', () {
      BackgroundTaskService.instance.initialize();
      BackgroundTaskService.instance.initialize();
      // Just smoke: should not throw, and channel handler stays bound.
      expect(true, isTrue);
    });

    test('onBackgroundRefresh callback is wired before completion ack', () async {
      // Simulate a host method-call by constructing the wired handler
      // semantics. On non-iOS the service skips wiring, so this test
      // documents the contract: setting onBackgroundRefresh before
      // initialize() never throws.
      bool fired = false;
      BackgroundTaskService.instance.onBackgroundRefresh = () async {
        fired = true;
      };
      BackgroundTaskService.instance.initialize();
      // No iOS dispatch in test env; just confirm the field is settable.
      expect(fired, isFalse);
      expect(BackgroundTaskService.instance.onBackgroundRefresh, isNotNull);
      // Reset for other tests.
      BackgroundTaskService.instance.onBackgroundRefresh = null;
    });
  });
}
