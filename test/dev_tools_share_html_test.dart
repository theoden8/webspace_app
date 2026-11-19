import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_file_picker.dart';
import 'helpers/fake_webview_controller.dart';
import 'helpers/isolations.dart';
import 'helpers/localized.dart';

const _html = '<html><body>hello</body></html>';

/// DEVTOOLS-003: the page's HTML shared, saved or copied from Developer
/// Tools' Export sheet, fetched once however many exports ask for it.
void main() {
  late List<String> clipboard;
  late List<Map<Object?, Object?>> shared;

  setUp(() {
    clipboard = [];
    shared = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'), (call) async {
      shared.add(call.arguments as Map<Object?, Object?>);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'), null);
  });

  Future<FakeWebViewController> open(WidgetTester tester) async {
    final view = FakeWebViewController()..htmlAnswer = () async => _html;
    final host = NestedDevToolsHost(
      name: 'example.com',
      siteId: SiteId('site-1'),
      currentUrl: 'https://news.example.com/a/b',
    )..controller = view;
    await pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeContainers()));
    await tester.pumpAndSettle();
    return view;
  }

  Future<void> export(WidgetTester tester, {required String action}) async {
    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pump();
  }

  testWidgets('DEVTOOLS-003: Copy puts the page\'s HTML on the clipboard',
      (tester) async {
    final view = await open(tester);
    await export(tester, action: 'Copy to clipboard');
    await tester.pumpAndSettle();
    expect(clipboard, [_html]);
    expect(find.text('HTML copied to clipboard'), findsOneWidget);
    expect(view.htmlFetches, 1);
  });

  testWidgets('DEVTOOLS-003: Share hands the HTML to the share sheet',
      (tester) async {
    await open(tester);
    await export(tester, action: 'Share HTML');
    await tester.pumpAndSettle();
    expect(shared, hasLength(1));
    expect(shared.single['text'], _html);
  });

  testWidgets('DEVTOOLS-003: Save offers <domain>_<time>.html and writes the '
      'HTML there', (tester) async {
    final dir = Directory.systemTemp.createTempSync('share_html');
    addTearDown(() => dir.deleteSync(recursive: true));
    final picker = FakeFilePicker.install()..savePath = '${dir.path}/page';
    await open(tester);
    await tester.runAsync(() async {
      await export(tester, action: 'Save to file');
      final file = File('${dir.path}/page.html');
      for (var i = 0;
          i < 50 && !(file.existsSync() && file.lengthSync() == _html.length);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    expect(picker.offered.single,
        matches(RegExp(r'^news\.example\.com_\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d\.html$')));
    expect(File('${dir.path}/page.html').readAsStringSync(), _html);
    expect(find.text('HTML saved'), findsOneWidget);
  });

  testWidgets('DEVTOOLS-003: an export asked for while the HTML is on its '
      'way waits for that fetch, and a later one reuses it', (tester) async {
    final view = await open(tester);
    final answer = Completer<String?>();
    view.htmlAnswer = () => answer.future;

    await export(tester, action: 'Copy to clipboard');
    await export(tester, action: 'Share HTML');
    expect(view.htmlFetches, 1, reason: 'the second joins the first');
    answer.complete(_html);
    await tester.pumpAndSettle();
    expect(clipboard, [_html]);
    expect(shared.single['text'], _html,
        reason: 'the export that waited gets the page too');

    await export(tester, action: 'Copy to clipboard');
    await tester.pumpAndSettle();
    expect(view.htmlFetches, 1);
    expect(clipboard, [_html, _html]);
  });
}
