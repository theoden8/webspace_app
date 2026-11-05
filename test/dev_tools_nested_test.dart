import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show ConsoleMessageLevel;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/isolations.dart';
import 'helpers/localized.dart';

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

void main() {
  setUp(() => DnsBlockService.instance.loadDomainsFromString('tracker.net'));
  tearDown(DnsBlockService.instance.resetForTest);

  testWidgets(
      'DEVTOOLS-008: a site\'s Developer Tools show its cookies, DNS and '
      'scripts', (tester) async {
    await pumpLocalized(tester,
        home: DevToolsScreen(
          host: WebViewModelDevToolsHost(
              WebViewModel(initUrl: 'https://example.com/')),
          isolation: fakeContainers(),
        ));
    for (final label in ['Console', 'Cookies', 'DNS', 'Logs']) {
      expect(_tab(label), findsOneWidget, reason: label);
    }
    expect(find.byTooltip('Scripts'), findsOneWidget);
  });

  testWidgets(
      'DEVTOOLS-008: over a nested screen they show the console and the logs, '
      'not the parent site\'s cookies, DNS or scripts', (tester) async {
    final host = NestedDevToolsHost(
      name: 'other.example',
      siteId: SiteId('site-1'),
      currentUrl: 'https://other.example/page',
    );
    await pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeContainers()));

    expect(_tab('Console'), findsOneWidget);
    expect(_tab('Logs'), findsOneWidget);
    expect(_tab('Cookies'), findsNothing);
    expect(_tab('DNS'), findsNothing);
    expect(find.byTooltip('Scripts'), findsNothing);
    expect(find.byTooltip('Export'), findsOneWidget,
        reason: 'Share HTML and Save Icon stay');

    host.appendConsole('hello from the nested page',
        level: ConsoleMessageLevel.LOG);
    await tester.pump();
    expect(find.textContaining('hello from the nested page'), findsOneWidget);
  });
}
