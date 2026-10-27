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
/// hides the window, it lists the sites with notifications on, and a press on
/// one opens it as a tap on its notification does. The status area itself is
/// a fake; the D-Bus side is held by status_notifier_tray_test.dart and the
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

  testWidgets('NOTIF-019 the tray lists the notifying sites while a close '
      'only hides the window, and goes when that is turned off', (tester) async {
    await pumpRealApp(tester,
        sites: [news, chat], prefs: {'keepRunningWhenClosed': true});

    expect(tray.lines, ['Show WebSpace', '-', 'Chat', '-', 'Quit WebSpace']);

    await tester.runAsync(() => AppPref.keepRunningWhenClosed.set(false));
    await settleRealApp(tester);
    expect(tray.lines, isNull);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 with the window closing as it always has there is '
      'no tray', (tester) async {
    await pumpRealApp(tester, sites: [news, chat]);

    expect(tray.lines, isNull);
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
        sites: [news, chat], prefs: {'keepRunningWhenClosed': true});

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

  void press(TrayAction action) => handlers.pressed(action);

  @override
  Future<bool> show(TrayMenu menu) async {
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
