// A download the OS or the user cleared from the cache (PLATFORM-010): its
// record no longer claims it, so the screens offer the download, and the
// launch fetches it again through the app-wide proxy, as its download button
// would. Each service is driven through its own load and its own download.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/web_intercept_native.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';

const _listUrl = 'https://lists.example/easylist.txt';

Map<String, Object?> _list(String id,
        {required String url, required bool enabled}) =>
    {
      'id': id,
      'name': id,
      'url': url,
      'enabled': enabled,
      'lastUpdated': '2026-01-01T00:00:00.000',
      'ruleCount': 100,
    };

String _dnsBody(List<String> extra) => [
      '# hagezi',
      for (var i = 0; i < 1200; i++) 'filler-$i.example',
      ...extra,
    ].join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(resetOutboundHttp);

  group('filter lists', () {
    final service = ContentBlockerService.instance;
    late MemoryFileStore store;

    setUp(() {
      service.reset();
      service.store = store = MemoryFileStore();
    });
    tearDown(service.reset);

    test('a downloaded list whose file is gone reads as not downloaded and '
        'is fetched again (PLATFORM-010)', () async {
      SharedPreferences.setMockInitialValues({
        'content_blocker_lists': jsonEncode([
          _list('purged', url: _listUrl, enabled: true),
          _list('off', url: 'https://lists.example/off.txt', enabled: false),
        ]),
      });
      final outbound =
          FakeOutbound(responder: (_) => http.Response('||ads.example^\n', 200));
      outboundHttp = outbound;

      final loaded =
          await service.initialize(native: WebInterceptNative.initialize());
      FilterList named(String id) =>
          service.lists.singleWhere((l) => l.id == id);
      expect(named('purged').lastUpdated, isNull);
      expect(named('purged').ruleCount, 0);
      expect(named('off').lastUpdated, isNull);
      expect(outbound.requested, isEmpty, reason: 'nothing fetched at load');

      expect(await loaded.refetchPurged(), 1);
      expect(outbound.requested, [Uri.parse(_listUrl)],
          reason: 'only the enabled list comes back');
      expect(named('purged').lastUpdated, isNotNull);
      expect(service.abpNetworkBlockHosts, contains('ads.example'));
      expect(await loaded.refetchPurged(), 0, reason: 'fetched once');
    });

    test('a list whose file is there is left as it is (PLATFORM-010)',
        () async {
      SharedPreferences.setMockInitialValues({
        'content_blocker_lists':
            jsonEncode([_list('kept', url: _listUrl, enabled: true)]),
      });
      await store.writeText('kept.txt', contents: '||kept.example^\n');
      final outbound = FakeOutbound();
      outboundHttp = outbound;

      final loaded =
          await service.initialize(native: WebInterceptNative.initialize());
      expect(service.lists.singleWhere((l) => l.id == 'kept').lastUpdated,
          isNotNull);
      expect(await loaded.refetchPurged(), 0);
      expect(outbound.requested, isEmpty);
    });
  });

  group('DNS blocklist', () {
    final service = DnsBlockService.instance;

    setUp(() {
      service.resetForTest();
      service.store = MemoryFileStore();
    });
    tearDown(service.resetForTest);

    test('an app-wide level whose list is gone is fetched again '
        '(PLATFORM-010)', () async {
      SharedPreferences.setMockInitialValues({'dns_block_level': 2});
      final outbound = FakeOutbound(
          responder: (req) => dnsMirrorUrlsForLevel(2).contains('${req.url}')
              ? http.Response(_dnsBody(['tracker.example']), 200)
              : http.Response('not found', 404));
      outboundHttp = outbound;

      final loaded = await service.initialize();
      expect(service.hasBlocklist, isFalse);
      expect(outbound.requested, isEmpty, reason: 'nothing fetched at load');

      expect(await loaded.refetchPurged(), isTrue);
      expect(service.isHostBlockedAtLevel('tracker.example', level: 2), isTrue);
      expect(await loaded.refetchPurged(), isFalse, reason: 'fetched once');
    });

    test('no level chosen fetches nothing (PLATFORM-010)', () async {
      SharedPreferences.setMockInitialValues({});
      final outbound = FakeOutbound();
      outboundHttp = outbound;

      expect(await (await service.initialize()).refetchPurged(), isFalse);
      expect(outbound.requested, isEmpty);
    });
  });

  group('ClearURLs rules', () {
    final service = ClearUrlService.instance;
    late Directory cache;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('purged_rules');
      useFakePathProvider(cache);
      service.resetForTest();
    });
    tearDown(() async {
      service.resetForTest();
      await cache.delete(recursive: true);
    });

    test('rules whose file is gone read as not downloaded and are fetched '
        'again (PLATFORM-010)', () async {
      SharedPreferences.setMockInitialValues(
          {'clearurl_last_updated': '2026-01-01T00:00:00.000'});
      final outbound = FakeOutbound(
          responder: (_) => http.Response(
              jsonEncode({
                'providers': {
                  'p': {
                    'urlPattern': r'example\.com',
                    'completeProvider': false,
                    'rules': [r'^utm_source$'],
                    'rawRules': [],
                    'exceptions': [],
                    'redirections': [],
                  },
                },
              }),
              200));
      outboundHttp = outbound;

      await service.initialize();
      expect(await service.getLastUpdated(), isNull);
      expect(outbound.requested, isEmpty, reason: 'nothing fetched at load');

      expect(await service.refetchPurged(), isTrue);
      expect(service.cleanUrl('https://example.com/p?utm_source=a'),
          'https://example.com/p');
      expect(await service.refetchPurged(), isFalse, reason: 'fetched once');
    });
  });
}
