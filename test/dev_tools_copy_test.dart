import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

/// The Copy button on each Developer Tools tab must copy exactly the entries
/// the tab is showing (DEVTOOLS-003/004): the level chips, the search query
/// and the DNS blocked/allowed chips all narrow what lands on the clipboard.
/// Sensitive log entries are the one exception — they reach the clipboard
/// only through the confirmation dialog.
class _StubCookieManager implements CookieManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubHost implements DevToolsHost {
  @override
  final String? siteId;
  _StubHost(this.siteId);

  @override
  String get name => 'stub';
  @override
  String get currentUrl => 'https://example.com/';
  @override
  String get iconUrl => 'https://example.com/';
  @override
  UserProxySettings? get proxy => null;
  @override
  WebViewController? get controller => null;
  @override
  List<ConsoleLogEntry> get consoleLogs => const [];
  @override
  set onConsoleLogChanged(VoidCallback? cb) {}
  @override
  List<Cookie> get cookies => const [];
  @override
  set cookies(List<Cookie> value) {}
  @override
  Set<BlockedCookie>? get blockedCookies => <BlockedCookie>{};
  @override
  List<UserScriptConfig>? get siteUserScripts => const [];
  @override
  Set<String> get enabledGlobalScriptIds => const {};
  @override
  void reload() {}
}

void main() {
  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    LogService.instance.resetForTest();
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
    LogService.instance.resetForTest();
    DnsBlockService.instance.loadDomainsFromString('');
  });

  Future<void> pumpDevTools(WidgetTester tester, {DevToolsHost? host}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DevToolsScreen(host: host, cookieManager: _StubCookieManager()),
    ));
    await tester.pumpAndSettle();
  }

  group('App Logs copy', () {
    testWidgets('copies the visible entries with no dialog when none are sensitive',
        (tester) async {
      LogService.instance.log('Nav', 'app started');
      LogService.instance.log('Theme', 'dark mode on');
      await pumpDevTools(tester);

      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('app started'));
      expect(clipboard.single, contains('dark mode on'));
    });

    testWidgets('sensitive entries are hidden and uncopied while the toggle is off',
        (tester) async {
      LogService.instance.log('Nav', 'app started');
      LogService.instance.log('Cookie', 'siteId=abc host=github.com',
          sensitivity: LogSensitivity.sensitive);
      await pumpDevTools(tester);

      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(clipboard.single, contains('app started'));
      expect(clipboard.single.contains('siteId=abc'), isFalse);
    });

    testWidgets('confirming the dialog copies the sensitive entries too',
        (tester) async {
      LogService.instance.log('Nav', 'app started');
      LogService.instance.log('Cookie', 'siteId=abc host=github.com',
          sensitivity: LogSensitivity.sensitive);
      await pumpDevTools(tester);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Copy'),
      ));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('app started'));
      expect(clipboard.single, contains('siteId=abc'));
    });

    testWidgets('cancelling the dialog copies nothing', (tester) async {
      LogService.instance.log('Cookie', 'siteId=abc host=github.com',
          sensitivity: LogSensitivity.sensitive);
      await pumpDevTools(tester);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'Cancel'),
      ));
      await tester.pumpAndSettle();

      expect(clipboard, isEmpty);
    });

    testWidgets('a level filter narrows what is copied', (tester) async {
      LogService.instance.log('Nav', 'app started');
      LogService.instance.log('Net', 'request failed', level: LogLevel.error);
      await pumpDevTools(tester);

      await tester.tap(find.widgetWithText(FilterChip, 'debug'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('request failed'));
      expect(clipboard.single.contains('app started'), isFalse);
    });
  });

  group('DNS log copy', () {
    testWidgets('copies only the entries the blocked/allowed filter leaves',
        (tester) async {
      DnsBlockService.instance.loadDomainsFromString('tracker.net');
      DnsBlockService.instance.recordHostRequest('site-1', 'tracker.net', true);
      DnsBlockService.instance.recordHostRequest('site-1', 'example.com', false);
      addTearDown(() => DnsBlockService.instance.clearStatsForSite('site-1'));

      await pumpDevTools(tester, host: _StubHost('site-1'));
      await tester.tap(find.text('DNS'));
      await tester.pumpAndSettle();

      // Blocked-only chip: the allowed lookup must not reach the clipboard.
      await tester.tap(find.widgetWithText(FilterChip, 'Blocked (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-dns-copy')));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('tracker.net'));
      expect(clipboard.single.contains('example.com'), isFalse);
    });
  });
}
