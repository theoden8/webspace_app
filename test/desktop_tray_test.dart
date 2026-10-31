import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/desktop_tray.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/services/tray_icon.dart';
import 'package:webspace/services/tray_menu_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// NOTIF-019 in the real app: the tray is there exactly while a close only
/// hides the window, with developer mode on or off, it lists the sites with
/// notifications on, and a press on one opens it as a tap on its
/// notification does. The status area itself is a fake; the D-Bus side is held by status_notifier_tray_test.dart and the
/// runners' by integration_test/tray_test.dart.
void main() {
  final chat = WebViewModel(initUrl: 'https://chat.example.test', name: 'Chat')
    ..notificationsEnabled = true;
  final news = WebViewModel(initUrl: 'https://news.example.test', name: 'News');

  late _FakeTray tray;

  setUp(() {
    tray = _FakeTray();
    DesktopTray.debugIconOverride = (handlers) => tray..handlers = handlers;
  });
  tearDown(() => DesktopTray.debugIconOverride = null);

  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  /// Keep running when closed, which is all the tray needs.
  const trayOn = {'keepRunningWhenClosed': true};

  testWidgets('NOTIF-019 the tray lists the notifying sites while a close '
      'only hides the window, and goes when that is turned off', (tester) async {
    await pumpRealApp(tester,
        sites: [news, chat], prefs: trayOn);

    expect(tray.lines, ['Show WebSpace', '-', 'Chat', '-', 'Quit WebSpace']);

    await tester.runAsync(() => AppPref.keepRunningWhenClosed.set(false));
    await settleRealApp(tester);
    expect(tray.lines, isNull);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 the menu is read again as the window hides',
      (tester) async {
    await pumpRealApp(tester, sites: [news, chat], prefs: trayOn);
    final shown = tray.shows;

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleRealApp(tester);
    expect(tray.shows, shown + 1);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleRealApp(tester);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 with the window closing as it always has there is '
      'no tray', (tester) async {
    await pumpRealApp(tester,
        sites: [news, chat], prefs: {'developerMode': true});

    expect(tray.lines, isNull);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 the tray needs only Keep running when closed, not '
      'developer mode', (tester) async {
    await pumpRealApp(tester, sites: [news, chat], prefs: trayOn);
    expect(tray.lines, contains('Show WebSpace'));

    await tester.runAsync(() => AppPref.developerMode.set(true));
    await settleRealApp(tester);
    await tester.runAsync(() => AppPref.developerMode.set(false));
    await settleRealApp(tester);
    expect(tray.lines, contains('Show WebSpace'),
        reason: 'the tray is no experiment, so developer mode leaves it');
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 a site pressed in the tray opens in the window it '
      'shows', (tester) async {
    const channel =
        MethodChannel('org.codeberg.theoden8.webspace/desktop_window');
    final asked = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      asked.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pumpRealApp(tester,
        sites: [news, chat], prefs: trayOn);

    await tester.runAsync(() async {
      tray.press(TrayOpenSite(chat.siteId));
    });
    await settleRealApp(tester);

    expect(asked, contains('show'));
    expect(inAppBar('Chat'), findsOneWidget);

    asked.clear();
    tray.press(const TrayShow());
    await settleRealApp(tester);
    expect(asked, ['show']);
  }, skip: !DesktopWindow.offered);
}

/// The desktop's status area: the menu last shown, or null once removed.
class _FakeTray implements TrayIcon {
  late TrayHandlers handlers;
  List<String>? lines;
  var shows = 0;

  void press(TrayAction action) => handlers.pressed(action);

  @override
  Future<bool> show(TrayMenu menu) async {
    shows++;
    lines = [
      for (final entry in menu.entries)
        switch (entry) {
          TrayItem(:final label) => label,
          TraySeparator() => '-',
        },
    ];
    return true;
  }

  @override
  Future<void> remove() async => lines = null;
}
