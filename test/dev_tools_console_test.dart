import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show ConsoleMessageLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

/// DEVTOOLS-001: a webview's console lines land in one capped log that the
/// Console tab draws, timestamped and coloured by level, and clears and
/// copies as the filter leaves them.
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

  NestedDevToolsHost host() => NestedDevToolsHost(
        name: 'example.com',
        siteId: SiteId('site-1'),
        currentUrl: 'https://example.com/',
      );

  Future<void> open(WidgetTester tester, {required DevToolsHost host}) async {
    await pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeContainers()));
    await tester.pumpAndSettle();
  }

  Color? colorOf(WidgetTester tester, {required String message}) => tester
      .widget<SelectableText>(find.ancestor(
          of: find.textContaining(message),
          matching: find.byType(SelectableText)))
      .style!
      .color;

  test('DEVTOOLS-001: the log keeps the last lines in order, telling its '
      'listener of each', () {
    final log = ConsoleLog();
    var told = 0;
    log.onChanged = () => told++;
    for (var i = 0; i < ConsoleLog.cap + 2; i++) {
      log.append('line $i', level: ConsoleMessageLevel.LOG);
    }
    expect(log.length, ConsoleLog.cap);
    expect(log.entries.first.message, 'line 2');
    expect(log.entries.last.message, 'line ${ConsoleLog.cap + 1}');
    expect(told, ConsoleLog.cap + 2);
    log.clear();
    expect(log.length, 0);
    expect(told, ConsoleLog.cap + 3);
  });

  test('DEVTOOLS-001: a site\'s Developer Tools read the log its webview '
      'writes', () {
    final site = WebViewModel(initUrl: 'https://example.com/');
    expect(identical(WebViewModelDevToolsHost(site).console, site.console),
        isTrue);
  });

  testWidgets('DEVTOOLS-001: lines arrive while open, timestamped, warnings '
      'amber and errors red', (tester) async {
    final h = host();
    await open(tester, host: h);
    h.console
      ..append('plain note', level: ConsoleMessageLevel.LOG)
      ..append('careful now', level: ConsoleMessageLevel.WARNING)
      ..append('it broke', level: ConsoleMessageLevel.ERROR);
    await tester.pump();

    expect(find.textContaining(RegExp(r'^\[\d\d:\d\d:\d\d\.\d{3}\] plain note$')),
        findsOneWidget);
    expect(colorOf(tester, message: 'careful now'), Colors.amber);
    expect(colorOf(tester, message: 'it broke'), Colors.red);
    expect(colorOf(tester, message: 'plain note'),
        isNot(anyOf(Colors.amber, Colors.red)));
  });

  testWidgets('DEVTOOLS-001: Copy takes only the lines the filter leaves and '
      'says how many; Clear empties the log', (tester) async {
    final h = host();
    h.console
      ..append('alpha one', level: ConsoleMessageLevel.LOG)
      ..append('beta two', level: ConsoleMessageLevel.WARNING)
      ..append('alpha three', level: ConsoleMessageLevel.ERROR);
    await open(tester, host: h);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Filter...'), 'alpha');
    await tester.pumpAndSettle();
    expect(find.textContaining('beta two'), findsNothing);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, hasLength(1));
    final lines = clipboard.single.split('\n');
    expect(lines, hasLength(2));
    expect(lines[0], endsWith('[LOG] alpha one'));
    expect(lines[1], endsWith('[ERROR] alpha three'));
    expect(find.text('Copied 2 console logs'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(h.console.length, 0);
    expect(find.textContaining('alpha one'), findsNothing);
  });
}
