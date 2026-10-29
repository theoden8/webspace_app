import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/desktop_tray.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/app_developer.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/services/tray_icon.dart';
import 'package:webspace/services/tray_menu_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/localized.dart';
import 'helpers/real_app.dart';

/// NOTIF-019 in the real app: the tray is there exactly while a close only
/// hides the window (on macOS, while its experiment is reachable too), it
/// lists the sites with notifications on, and a press on one opens it as a
/// tap on its notification does. The status area itself is
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
  tearDown(() {
    DesktopTray.debugIconOverride = null;
    DesktopTray.debugExperimental = null;
  });

  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  /// Keep running when closed, and the Tray icon experiment reachable where
  /// it is one.
  const trayOn = {
    'keepRunningWhenClosed': true,
    'developerMode': true,
    'experimentalDesktopTray': true,
  };

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
    await pumpRealApp(tester, sites: [news, chat], prefs: {
      'developerMode': true,
      'experimentalDesktopTray': true,
    });

    expect(tray.lines, isNull);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 on Linux the tray needs only Keep running when '
      'closed', (tester) async {
    DesktopTray.debugExperimental = false;
    await pumpRealApp(tester,
        sites: [news, chat], prefs: {'keepRunningWhenClosed': true});
    expect(tray.lines, contains('Show WebSpace'));

    await tester.runAsync(() => AppPref.keepRunningWhenClosed.set(false));
    await settleRealApp(tester);
    expect(tray.lines, isNull);
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 on macOS the tray waits for its experiment, which '
      'developer mode gates', (tester) async {
    DesktopTray.debugExperimental = true;
    await pumpRealApp(tester,
        sites: [news, chat], prefs: {'keepRunningWhenClosed': true});
    expect(tray.lines, isNull, reason: 'the experiment is off');

    await tester.runAsync(() async {
      await AppPref.developerMode.set(true);
      await AppPref.experimentalDesktopTray.set(true);
    });
    await settleRealApp(tester);
    expect(tray.lines, contains('Show WebSpace'));

    await tester.runAsync(() => AppPref.developerMode.set(false));
    await settleRealApp(tester);
    expect(tray.lines, isNull,
        reason: 'an experiment is reachable only in developer mode');
  }, skip: !DesktopWindow.offered);

  testWidgets('NOTIF-019 the Experimental group offers the tray only where '
      'it waits for its experiment', (tester) async {
    late AppLocalizations loc;
    await pumpLocalized(tester, home: Builder(builder: (context) {
      loc = AppLocalizations.of(context);
      return const SizedBox();
    }));
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.desktopTray, on: true);
    addTearDown(() => ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.desktopTray, on: false));

    DesktopTray.debugExperimental = true;
    expect(experimentsOn(loc), contains(loc.appSettingsExperimentalDesktopTray));

    DesktopTray.debugExperimental = false;
    expect(experimentsOn(loc),
        isNot(contains(loc.appSettingsExperimentalDesktopTray)));
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
