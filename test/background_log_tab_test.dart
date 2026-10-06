import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';

class _StubCookieManager implements CookieManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// DEVTOOLS-011: the Background tab exists only in developer mode, shows what
/// the background log kept, and keeps entries that name sites behind the
/// switch and the copy confirmation.
void main() {
  late List<String> clipboard;

  setUp(() async {
    clipboard = [];
    LogService.instance.resetForTest();
    BackgroundLog.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    DeveloperModeService.instance.debugSet(false);
    BackgroundLog.instance.resetForTest();
    LogService.instance.resetForTest();
  });

  Future<void> pump(WidgetTester tester, {bool startOnBackground = false}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevToolsScreen(
        cookieManager: _StubCookieManager(),
        startOnBackground: startOnBackground,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('no Background tab outside developer mode', (tester) async {
    DeveloperModeService.instance.debugSet(false);
    await pump(tester);
    expect(find.text('Background'), findsNothing);
  });

  testWidgets('developer mode opens on the Background tab with its entries',
      (tester) async {
    DeveloperModeService.instance.debugSet(true);
    await BackgroundLog.instance.setRecording(true);
    BackgroundLog.instance.appState =
        () => const [MapEntry('app.notificationSitesLoaded', '0')];
    BackgroundLog.instance.record('BackgroundTask',
        'cancel refresh — notif sites: 1 enabled, 0 loaded',
        sensitive: 'unloaded notification site "Mail"');
    await pump(tester, startOnBackground: true);

    expect(find.text('Background'), findsOneWidget);
    expect(find.textContaining('0 loaded'), findsOneWidget);
    expect(find.textContaining('app.notificationSitesLoaded: 0'), findsOneWidget);
    expect(find.textContaining('"Mail"'), findsNothing);

    await tester.tap(find.byKey(const Key('background-log-sensitive')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"Mail"'), findsOneWidget);
  });

  testWidgets('copying entries that name sites asks first', (tester) async {
    DeveloperModeService.instance.debugSet(true);
    await BackgroundLog.instance.setRecording(true);
    BackgroundLog.instance.record('BackgroundTask', 'wake site 1/1: loaded',
        sensitive: 'wake site 1/1 is "Mail"');
    await pump(tester, startOnBackground: true);

    await tester.tap(find.byKey(const Key('background-log-copy')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(clipboard.single, contains('wake site 1/1: loaded'));
    expect(clipboard.single.contains('Mail'), isFalse);

    await tester.tap(find.byKey(const Key('background-log-sensitive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('background-log-copy')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Cancel'),
    ));
    await tester.pumpAndSettle();
    expect(clipboard, hasLength(1));

    await tester.tap(find.byKey(const Key('background-log-copy')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Copy'),
    ));
    await tester.pumpAndSettle();
    expect(clipboard.last, contains('"Mail"'));
  });

  testWidgets('a landscape phone still has room for the log', (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DeveloperModeService.instance.debugSet(true);
    await BackgroundLog.instance.setRecording(true);
    BackgroundLog.instance.appState = () => [
          for (var i = 0; i < 20; i++) MapEntry('app.row$i', 'value'),
        ];
    BackgroundLog.instance.record('BackgroundTask', 'the newest line');
    await pump(tester, startOnBackground: true);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('the newest line'), findsOneWidget);
  });

  testWidgets('nothing is recorded while developer mode is off', (tester) async {
    DeveloperModeService.instance.debugSet(true);
    await BackgroundLog.instance.setRecording(false);
    BackgroundLog.instance.record('BackgroundTask', 'schedule refresh');
    await pump(tester, startOnBackground: true);
    expect(find.text('No background events recorded yet'), findsOneWidget);
  });
}
