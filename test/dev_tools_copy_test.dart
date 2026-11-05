import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/localized.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/webview_config.dart';
import 'helpers/isolations.dart';

class _StubHost implements DevToolsHost {
  @override
  final SiteId? siteId;
  _StubHost(this.siteId);

  @override
  String get name => 'stub';
  @override
  String get currentUrl => 'https://example.com/';
  @override
  String get iconUrl => 'https://example.com/';
  @override
  Uint8List? get customIcon => null;
  @override
  OutboundProxy get proxy => OutboundProxy.app;
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
  Set<UserScriptId> get enabledGlobalScriptIds => const {};
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
    await pumpLocalized(tester,
        home: DevToolsScreen(host: host, isolation: fakeSharedJar()));
    await tester.pumpAndSettle();
  }

  group('App Logs copy', () {
    testWidgets('copies the visible entries with no dialog when none are sensitive',
        (tester) async {
      LogTag.navigation.debug('app started');
      LogTag.lifecycle.debug('dark mode on');
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
      LogTag.navigation.debug('app started');
      LogTag.cookieIsolation.debug('siteId=abc host=github.com', sensitive: true);
      await pumpDevTools(tester);

      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(clipboard.single, contains('app started'));
      expect(clipboard.single.contains('siteId=abc'), isFalse);
    });

    testWidgets('confirming the dialog copies the sensitive entries too',
        (tester) async {
      LogTag.navigation.debug('app started');
      LogTag.cookieIsolation.debug('siteId=abc host=github.com', sensitive: true);
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
      LogTag.cookieIsolation.debug('siteId=abc host=github.com', sensitive: true);
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
      LogTag.navigation.debug('app started');
      LogTag.proxy.error('request failed');
      await pumpDevTools(tester);

      await tester.tap(find.widgetWithText(FilterChip, 'debug'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-logs-copy')));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('request failed'));
      expect(clipboard.single.contains('app started'), isFalse);
    });
  });

  group('Blocking log', () {
    final site = SiteId('site-1');

    setUp(() => DnsBlockService.instance.loadDomainsFromString('tracker.net'));
    tearDown(() => DnsBlockService.instance.clearStatsForSite(site));

    Future<void> openBlocking(WidgetTester tester) async {
      await pumpDevTools(tester, host: _StubHost(site));
      await tester.tap(find.text('Blocking'));
      await tester.pumpAndSettle();
    }

    testWidgets('copies only the entries the filter chips leave, each naming its blocker (DNS-014)',
        (tester) async {
      DnsBlockService.instance.recordVerdict(site,
          query: const HostQuery('tracker.net'),
          verdict: const Blocked(BlockSource.dns));
      DnsBlockService.instance.recordVerdict(site,
          query: const HostQuery('ads.example'),
          verdict: const Blocked(BlockSource.abp));
      DnsBlockService.instance.recordVerdict(site,
          query: const HostQuery('example.com'), verdict: const Allowed());

      await openBlocking(tester);
      expect(find.text('DNS'), findsOneWidget, reason: 'the DNS row carries its tag');
      expect(find.text('ABP'), findsOneWidget, reason: 'the ABP row carries its tag');

      await tester.tap(find.widgetWithText(FilterChip, 'DNS (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-blocking-copy')));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('BLOCKED DNS tracker.net'));
      expect(clipboard.single.contains('ads.example'), isFalse);
      expect(clipboard.single.contains('example.com'), isFalse);
    });

    testWidgets('an engine block drained from Android reaches the log as ABP, naming the request its rule matched (CB-012)',
        (tester) async {
      WebInterceptNative.applyBlockEvents(site, list: [
        {
          'host': 'api.github.com',
          'blocked': true,
          'source': 'abp',
          'url': 'https://api.github.com/_private/browser/stats',
          'sourceUrl': 'https://github.com/',
          'requestType': 'xmlhttprequest',
          'count': 3,
        },
        {'host': 'tracker.net', 'blocked': true, 'source': 'dns', 'count': 1},
        {'host': 'api.github.com', 'blocked': false, 'count': 5},
      ]);

      await openBlocking(tester);
      expect(
          find.textContaining(
              'xmlhttprequest https://api.github.com/_private/browser/stats'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'ABP (3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-blocking-copy')));
      await tester.pumpAndSettle();

      expect(
          clipboard.single,
          contains('BLOCKED ABP xmlhttprequest '
              'https://api.github.com/_private/browser/stats'));
      expect(clipboard.single.contains('tracker.net'), isFalse);
      expect(find.widgetWithText(FilterChip, 'Allowed (5)'), findsOneWidget);
    });

    testWidgets('a DNS block ABP would also stop is tagged with both, and the ABP chip takes it in (CB-012)',
        (tester) async {
      WebInterceptNative.applyBlockEvents(site, list: [
        {
          'host': 'tracker.net',
          'blocked': true,
          'source': 'dns',
          'alsoAbp': true,
          'count': 4,
        },
        {'host': 'dns-only.net', 'blocked': true, 'source': 'dns', 'count': 1},
        {'host': 'ads.example', 'blocked': true, 'source': 'abp', 'count': 2},
      ]);

      await openBlocking(tester);
      expect(find.text('DNS, also ABP'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'DNS (5)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'ABP (6)'), findsOneWidget,
          reason: 'ABP stops its own 2 and 4 of the DNS blocks');

      await tester.tap(find.widgetWithText(FilterChip, 'ABP (6)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('devtools-blocking-copy')));
      await tester.pumpAndSettle();

      expect(clipboard.single, contains('BLOCKED DNS+ABP tracker.net'));
      expect(clipboard.single, contains('BLOCKED ABP ads.example'));
      expect(clipboard.single.contains('dns-only.net'), isFalse);
    });

    testWidgets('the tab is there while a DNS blocklist is loaded (DNS-014)',
        (tester) async {
      await pumpDevTools(tester, host: _StubHost(site));
      expect(find.text('Blocking'), findsOneWidget);
    });

    testWidgets('the tab is gone while neither blocker has data (DNS-014)',
        (tester) async {
      DnsBlockService.instance.loadDomainsFromString('');
      await pumpDevTools(tester, host: _StubHost(site));
      expect(find.text('Blocking'), findsNothing);
    });
  });
}
