import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show ConsoleMessageLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';
import 'helpers/localized.dart';

NestedDevToolsHost _host() => NestedDevToolsHost(
      name: 'example.com',
      siteId: SiteId('site-1'),
      currentUrl: 'https://example.com/',
    );

Future<void> _open(WidgetTester tester, {required NestedDevToolsHost host}) =>
    pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeContainers()));

Finder get _input => find.widgetWithText(TextField, 'Evaluate JavaScript...');

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).last).controller!.text;

/// The console line reading [text], as drawn.
TextStyle _lineStyle(WidgetTester tester, {required String text}) =>
    tester.widget<SelectableText>(find.widgetWithText(SelectableText, text)).style!;

Future<void> _run(WidgetTester tester, {required String source}) async {
  await tester.enterText(_input, source);
  await tester.tap(find.byTooltip('Run'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'DEVTOOLS-007: with no webview the input, Run and the prompt are '
      'disabled', (tester) async {
    await _open(tester, host: _host());
    expect(tester.widget<TextField>(find.byType(TextField).last).enabled,
        isFalse);
    expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.play_arrow))
            .onPressed,
        isNull);
    final context = tester.element(find.byType(DevToolsScreen));
    expect(tester.widget<Text>(find.text('>')).style!.color,
        Theme.of(context).disabledColor);
  });

  testWidgets(
      'DEVTOOLS-007: Run echoes the input and injects it as code, never '
      'through eval', (tester) async {
    final host = _host()..controller = FakeWebViewController();
    final view = host.controller! as FakeWebViewController;
    await _open(tester, host: host);

    await _run(tester, source: 'document.title');

    final context = tester.element(find.byType(DevToolsScreen));
    final echo = _lineStyle(tester, text: '> document.title');
    expect(echo.color, Theme.of(context).colorScheme.primary);
    expect(echo.fontWeight, FontWeight.bold);
    expect(view.evaluated.where((js) => js.contains('\ndocument.title\n')),
        isNotEmpty);
    for (final js in view.evaluated) {
      expect(js, isNot(contains('eval(')));
      expect(js, isNot(contains('Function(')));
    }
    expect(_inputText(tester), isEmpty);

    await tester.enterText(_input, 'location.href');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.text('> location.href'), findsOneWidget, reason: 'Enter runs');
  });

  testWidgets('DEVTOOLS-007: an error the page reports is a red line',
      (tester) async {
    final host = _host()..controller = FakeWebViewController();
    await _open(tester, host: host);
    host.appendConsole('Unexpected token', level: ConsoleMessageLevel.ERROR);
    await tester.pump();
    final line = find.ancestor(
        of: find.textContaining('Unexpected token'),
        matching: find.byType(SelectableText));
    expect(tester.widget<SelectableText>(line).style!.color, Colors.red);
  });

  testWidgets(
      'DEVTOOLS-007: up walks back through the commands run, down forward '
      'and then to an empty input', (tester) async {
    final host = _host()..controller = FakeWebViewController();
    await _open(tester, host: host);
    await _run(tester, source: 'first()');
    await _run(tester, source: 'second()');

    Future<String> press(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
      return _inputText(tester);
    }

    expect(await press('Previous command'), 'second()');
    expect(await press('Previous command'), 'first()');
    expect(await press('Next command'), 'second()');
    expect(await press('Next command'), isEmpty);
  });
}
