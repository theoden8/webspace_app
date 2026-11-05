import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

final _global = UserScriptConfig(name: 'global.js', source: 'g()');
final _otherGlobal = UserScriptConfig(name: 'other-global.js', source: 'o()');

/// The site's scripts sheet, opened from its Developer Tools as the user
/// opens it.
Future<void> _openSheet(WidgetTester tester, {required WebViewModel site}) async {
  await pumpLocalized(tester,
      home: DevToolsScreen(
        host: WebViewModelDevToolsHost(site),
        isolation: fakeContainers(),
        globalUserScripts: [_global, _otherGlobal],
      ));
  await tester.tap(find.byTooltip('Scripts'));
  await tester.pumpAndSettle();
}

Finder _inSheet(Finder finder) => find.descendant(
    of: find.byType(DraggableScrollableSheet), matching: finder);

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

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  testWidgets(
      'DEVTOOLS-006: the sheet lists the site\'s scripts and the globals it '
      'runs, each with its state and injection time', (tester) async {
    await _openSheet(tester,
        site: WebViewModel(
          initUrl: 'https://example.com/',
          userScripts: [
            UserScriptConfig(
                name: 'start.js',
                source: 'console.log("at start")',
                injectionTime: UserScriptInjectionTime.atDocumentStart),
            UserScriptConfig(name: 'end.js', source: 'e()', enabled: false),
          ],
          enabledGlobalScriptIds: {_global.id},
        ));

    expect(_inSheet(find.text('3')), findsOneWidget, reason: 'the count');
    for (final name in ['global.js', 'start.js', 'end.js']) {
      expect(_inSheet(find.text(name)), findsOneWidget, reason: name);
    }
    expect(_inSheet(find.text('other-global.js')), findsNothing,
        reason: 'a global the site does not run');
    expect(_inSheet(find.text('global')), findsOneWidget);
    expect(_inSheet(find.text('document start')), findsOneWidget);
    expect(_inSheet(find.text('document end')), findsNWidgets(2));
    expect(_inSheet(find.byIcon(Icons.code_off)), findsOneWidget,
        reason: 'end.js is off');

    await tester.tap(_inSheet(find.text('start.js')));
    await tester.pumpAndSettle();
    expect(_inSheet(find.text('console.log("at start")')), findsOneWidget);
    await tester.tap(_inSheet(find.byIcon(Icons.copy)));
    await tester.pumpAndSettle();
    expect(clipboard, ['console.log("at start")']);
  });

  testWidgets('DEVTOOLS-006: a site with no scripts says so', (tester) async {
    await _openSheet(tester,
        site: WebViewModel(initUrl: 'https://example.com/'));
    expect(_inSheet(find.text('No user scripts configured')), findsOneWidget);
  });
}
