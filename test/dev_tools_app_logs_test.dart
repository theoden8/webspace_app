import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/app_developer.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/widgets/dev_tools_parts.dart';

import 'helpers/fake_file_picker.dart';
import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// DEVTOOLS-004: App Logs shows the log as it streams, follows it from the
/// bottom and holds still while the reader is scrolled up, filters by level,
/// exports the whole log without its sensitive half, and opens from App
/// Settings with no site.
void main() {
  setUp(LogService.instance.resetForTest);
  tearDown(LogService.instance.resetForTest);

  Future<void> open(WidgetTester tester) async {
    await pumpLocalized(tester,
        size: const Size(800, 900),
        home: DevToolsScreen(isolation: fakeContainers()));
    await tester.pumpAndSettle();
  }

  Finder lineWith(String text) => find.textContaining(text);

  testWidgets('DEVTOOLS-004: a line arriving while the tab is open shows, '
      'timestamped and tagged, newest at the bottom', (tester) async {
    LogTag.navigation.debug('first');
    await open(tester);
    expect(find.textContaining(RegExp(r'^\[\d\d:\d\d:\d\d(\.\d+)?\] \[Navigation\] first$')),
        findsOneWidget);

    LogTag.lifecycle.info('second');
    await tester.pump();
    expect(lineWith('second'), findsOneWidget, reason: 'no refresh needed');
    expect(tester.getTopLeft(lineWith('second')).dy,
        greaterThan(tester.getTopLeft(lineWith('first')).dy));
  });

  testWidgets('DEVTOOLS-004: the level chips narrow what shows', (tester) async {
    LogTag.navigation.debug('a debug line');
    LogTag.navigation.error('an error line');
    await open(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'debug'));
    await tester.pumpAndSettle();
    expect(lineWith('a debug line'), findsNothing);
    expect(lineWith('an error line'), findsOneWidget);
  });

  testWidgets('DEVTOOLS-004: scrolled up, a new line moves nothing; back at '
      'the bottom the view follows the log again', (tester) async {
    for (var i = 0; i < 120; i++) {
      LogTag.navigation.debug('line $i');
    }
    await open(tester);
    final list = find.descendant(
        of: find.byType(LogLines<LogEntry>), matching: find.byType(ListView));
    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    final reading = lineWith('line 100');
    expect(reading, findsOneWidget);
    final before = tester.getTopLeft(reading).dy;

    for (var i = 120; i < 125; i++) {
      LogTag.navigation.debug('line $i');
    }
    await tester.pump();
    expect(tester.getTopLeft(lineWith('line 100')).dy, before,
        reason: 'what the reader is on stays put');

    await tester.drag(list, const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(lineWith('line 124'), findsOneWidget, reason: 'the held lines land');
    LogTag.navigation.debug('line 125');
    await tester.pump();
    expect(lineWith('line 125'), findsOneWidget, reason: 'and it follows again');
  });

  testWidgets('DEVTOOLS-004: Export writes the whole log, whatever the '
      'filters, and never a sensitive entry', (tester) async {
    final dir = Directory.systemTemp.createTempSync('app_logs');
    addTearDown(() => dir.deleteSync(recursive: true));
    final picker = FakeFilePicker.install()..savePath = '${dir.path}/logs.txt';
    LogTag.navigation.debug('a debug line');
    LogTag.navigation.error('an error line');
    LogTag.cookieIsolation.debug('siteId=abc', sensitive: true);
    await open(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'debug'));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final file = File('${dir.path}/logs.txt');
    await tester.runAsync(() async {
      await tester.tap(find.text('Export'));
      for (var i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(picker.offered.single.fileName,
        matches(RegExp(r'^webspace_logs_.*\.txt$')));
    expect(picker.offered.single.mimeType, 'text/plain');
    final text = file.readAsStringSync();
    expect(text, contains('a debug line'), reason: 'filters do not narrow it');
    expect(text, contains('an error line'));
    expect(text, isNot(contains('siteId=abc')));
  });

  testWidgets('DEVTOOLS-004: App Settings opens the logs with no site, the '
      'Logs tab alone', (tester) async {
    await pumpLocalized(tester,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openAppLogs(context),
            child: const Text('open'),
          ),
        ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(DevToolsScreen), findsOneWidget);
    expect(find.byType(Tab), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Logs'), findsOneWidget);
  });
}
