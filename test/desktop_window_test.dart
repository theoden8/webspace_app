import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/settings/app_prefs.dart';

/// NOTIF-018: the runner decides a close as it lands, from what
/// [DesktopWindow] told it of the setting, so what it was told is the
/// setting at every moment. The close itself, the hide and the Dock and
/// relaunch paths back are the runners' own, held by
/// integration_test/close_keeps_running_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('org.codeberg.theoden8.webspace/desktop_window');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    AppPref.keepRunningWhenClosed.debugValue = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppPref.keepRunningWhenClosed.debugValue = false;
  });

  List<Object?> told() => [
        for (final c in calls)
          if (c.method == 'setKeepRunningWhenClosed') (c.arguments as Map)['keep'],
      ];

  test('NOTIF-018 the runner hears the setting at start and on every change',
      () async {
    final window = DesktopWindow(offered: true);
    addTearDown(window.stop);
    window.start();
    await pumpEventQueue();
    expect(told(), [false], reason: 'a runner left at its default would be '
        'right only by luck');

    AppPref.keepRunningWhenClosed.debugValue = true;
    await pumpEventQueue();
    AppPref.keepRunningWhenClosed.debugValue = false;
    await pumpEventQueue();
    expect(told(), [false, true, false]);
  });

  test('NOTIF-018 a host with no window to hide is told nothing', () async {
    final window = DesktopWindow(offered: false);
    addTearDown(window.stop);
    window.start();
    AppPref.keepRunningWhenClosed.debugValue = true;
    await window.show();
    await pumpEventQueue();
    expect(calls, isEmpty);
  });

  test('NOTIF-018 show asks the runner for the window', () async {
    await DesktopWindow(offered: true).show();
    expect(calls.map((c) => c.method), ['show']);
  });

  test('a runner without the channel closes as it always has', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final window = DesktopWindow(offered: true);
    addTearDown(window.stop);
    window.start();
    await expectLater(window.show(), completes);
  });

  test('NOTIF-018 the setting is off until the user turns it on', () {
    expect(AppPref.keepRunningWhenClosed.fallback, isFalse,
        reason: 'a close that did not quit would surprise everyone who never '
            'asked for it');
  });
}
