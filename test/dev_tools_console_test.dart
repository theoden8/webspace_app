import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show ConsoleMessageLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// DEVTOOLS-001. The Console tab shows each line the page wrote with its
/// time, warnings in amber and errors in red; Clear empties it, and Copy
/// takes the lines the filter leaves and says how many.
void main() {
  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  Future<NestedDevToolsHost> openConsole(WidgetTester tester) async {
    final host = NestedDevToolsHost(
      name: 'example.com',
      siteId: SiteId('site-1'),
      currentUrl: 'https://example.com/',
    );
    host.consoleLogs.addAll([
      ConsoleLogEntry(
          timestamp: DateTime(2026, 1, 2, 9, 4, 5, 7),
          message: 'loaded',
          level: ConsoleMessageLevel.LOG),
      ConsoleLogEntry(
          timestamp: DateTime(2026, 1, 2, 9, 4, 6, 80),
          message: 'slow script',
          level: ConsoleMessageLevel.WARNING),
      ConsoleLogEntry(
          timestamp: DateTime(2026, 1, 2, 9, 4, 7, 900),
          message: 'broken script',
          level: ConsoleMessageLevel.ERROR),
    ]);
    await pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeContainers()));
    await tester.pumpAndSettle();
    return host;
  }

  Color? lineColor(WidgetTester tester, {required String text}) =>
      tester.widget<SelectableText>(find.widgetWithText(SelectableText, text)).style!.color;

  testWidgets('each line shows its time, warnings amber and errors red '
      '(DEVTOOLS-001)', (tester) async {
    await openConsole(tester);
    final body = Theme.of(tester.element(find.byType(DevToolsScreen)))
        .textTheme
        .bodyMedium
        ?.color;
    expect(lineColor(tester, text: '[09:04:05.007] loaded'), body);
    expect(lineColor(tester, text: '[09:04:06.080] slow script'), Colors.amber);
    expect(lineColor(tester, text: '[09:04:07.900] broken script'), Colors.red);
  });

  testWidgets('Clear removes every line (DEVTOOLS-001)', (tester) async {
    final host = await openConsole(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(host.consoleLogs, isEmpty);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('Copy takes only the filtered lines and counts them '
      '(DEVTOOLS-001)', (tester) async {
    await openConsole(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Filter...'), 'script');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(clipboard, [
      '[09:04:06] [WARN] slow script\n[09:04:07] [ERROR] broken script',
    ]);
    expect(find.text('Copied 2 console logs'), findsOneWidget);
  });
}
