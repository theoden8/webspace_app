import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';

/// Lists that block what they are told to, at the level they are told to,
/// and log every question so a test can see what was asked.
class _Lists implements BlockLists {
  _Lists({
    this.dnsHosts = const {},
    this.dnsLevel = 2,
    this.abpHosts = const {},
    this.redirects = const {},
  });

  final Set<String> dnsHosts;
  final int dnsLevel;
  final Set<String> abpHosts;
  final Map<String, String> redirects;
  final asked = <String>[];

  String _host(String url) => Uri.parse(url).host;

  @override
  bool dnsBlocksUrl(String url, {required int level}) =>
      dnsBlocksHost(_host(url), level: level);

  @override
  bool dnsBlocksHost(String host, {required int level}) {
    asked.add('dns:$host@$level');
    return level >= dnsLevel && dnsHosts.contains(host);
  }

  @override
  bool abpBlocksUrl(String url,
      {required String sourceUrl, required String requestType}) {
    asked.add('abp:$url from $sourceUrl as $requestType');
    return abpHosts.contains(_host(url));
  }

  @override
  bool abpBlocksHost(String host) {
    asked.add('abp:$host');
    return abpHosts.contains(host);
  }

  @override
  String? abpRedirect(String url,
          {required String sourceUrl, required String requestType}) =>
      redirects[url];
}

const _on = (dnsLevel: 3, contentBlock: true);
UrlQuery _url(String url) =>
    UrlQuery(url, sourceUrl: 'https://site.example/', requestType: 'other');

void main() {
  group('BlockDecision.decide', () {
    test('a request both lists block counts against DNS, marked as one ABP stops too (CB-012)',
        () {
      final lists = _Lists(dnsHosts: {'t.example'}, abpHosts: {'t.example'});
      final v = BlockDecision.decide(_url('https://t.example/x'),
          policy: _on, lists: lists);
      expect(v, isA<Blocked>().having((b) => b.alsoAbp, 'alsoAbp', isTrue));
      expect(v.source, BlockSource.dns);
    });

    test('a DNS block the filter lists would let through is DNS alone', () {
      final lists = _Lists(dnsHosts: {'t.example'});
      final v = BlockDecision.decide(const HostQuery('t.example'),
          policy: _on, lists: lists);
      expect(v, isA<Blocked>().having((b) => b.alsoAbp, 'alsoAbp', isFalse));
      expect(lists.asked, ['dns:t.example@3', 'abp:t.example']);
    });

    test('with content blocking off a DNS block never asks the filter lists',
        () {
      final lists = _Lists(dnsHosts: {'t.example'}, abpHosts: {'t.example'});
      final v = BlockDecision.decide(_url('https://t.example/x'),
          policy: (dnsLevel: 3, contentBlock: false), lists: lists);
      expect(v, isA<Blocked>().having((b) => b.alsoAbp, 'alsoAbp', isFalse));
      expect(lists.asked.where((q) => q.startsWith('abp:')), isEmpty);
    });

    test('what DNS lets through goes to the filter lists', () {
      final lists = _Lists(abpHosts: {'ads.example'});
      final v = BlockDecision.decide(_url('https://ads.example/a.js'),
          policy: _on, lists: lists);
      expect(v.source, BlockSource.abp);
      expect(lists.asked.last,
          'abp:https://ads.example/a.js from https://site.example/ as other');
    });

    test('a filter-list block with a stub is a redirect', () {
      const url = 'https://ads.example/gtm.js';
      final lists = _Lists(
          abpHosts: {'ads.example'}, redirects: {url: 'data:text/plain,'});
      final v = BlockDecision.decide(_url(url), policy: _on, lists: lists);
      expect(v, isA<Redirect>().having((r) => r.url, 'url', 'data:text/plain,'));
      expect(v.source, BlockSource.abp);
    });

    test('content blocking off never asks the filter lists', () {
      final lists = _Lists(abpHosts: {'ads.example'});
      final v = BlockDecision.decide(_url('https://ads.example/a.js'),
          policy: (dnsLevel: 3, contentBlock: false), lists: lists);
      expect(v, isA<Allowed>());
      expect(lists.asked.where((q) => q.startsWith('abp:')), isEmpty);
    });

    test('DNS off never asks the DNS lists', () {
      final lists = _Lists(dnsHosts: {'t.example'});
      final v = BlockDecision.decide(_url('https://t.example/x'),
          policy: (dnsLevel: kDnsLevelOff, contentBlock: true), lists: lists);
      expect(v, isA<Allowed>());
      expect(lists.asked.where((q) => q.startsWith('dns:')), isEmpty);
    });

    test("DNS is asked at the site's own level", () {
      final lists = _Lists(dnsHosts: {'t.example'}, dnsLevel: 4);
      expect(
          BlockDecision.decide(_url('https://t.example/'),
              policy: _on, lists: lists),
          isA<Allowed>());
      expect(lists.asked.first, 'dns:t.example@3');
    });

    test('a host query asks the host lookups', () {
      final lists = _Lists(abpHosts: {'cdn.example'});
      final v = BlockDecision.decide(const HostQuery('cdn.example'),
          policy: _on, lists: lists);
      expect(v.source, BlockSource.abp);
      expect(lists.asked, ['dns:cdn.example@3', 'abp:cdn.example']);
    });
  });

  group('pageBlockReplies', () {
    Map<String, Object> ask(String url, {String type = 'image', bool issued = false}) =>
        {'url': url, 'type': type, 'issued': issued};

    test('one reply per ask of the batch, in its order, each judged as its type', () {
      final judged = <PageRequest>[];
      final replies = pageBlockReplies(
        [
          ask('https://a.example/1'),
          7,
          ask('https://b.example/2', type: 'script', issued: true),
          ask('https://c.example/3', type: 'xhr'),
        ],
        judge: (request) {
          judged.add(request);
          return switch (Uri.parse(request.url).host) {
            'a.example' => const Allowed(),
            'b.example' => const Blocked(BlockSource.abp),
            _ => const Redirect('data:text/javascript,'),
          };
        },
      );
      expect(replies, [false, false, true, 'data:text/javascript,']);
      expect(judged, [
        (url: 'https://a.example/1', requestType: 'image', issued: false),
        (url: 'https://b.example/2', requestType: 'script', issued: true),
        (url: 'https://c.example/3', requestType: 'xhr', issued: false),
      ], reason: 'each ask judged once, so each is recorded once');
    });

    test('an empty batch asks nothing', () {
      expect(pageBlockReplies(const [], judge: (_) => fail('judged')), isEmpty);
    });
  });

  group('countsForPage (CB-012)', () {
    const before = (url: 'https://a.example/x', requestType: 'xhr', issued: false);
    const issued = (url: 'https://a.example/x', requestType: 'script', issued: true);
    const dns = Blocked(BlockSource.dns);
    const dnsAlsoAbp = Blocked(BlockSource.dns, alsoAbp: true);
    const abp = Blocked(BlockSource.abp);

    bool counts(PageRequest r,
            {required BlockVerdict verdict, bool webKitReports = false}) =>
        countsForPage(r, verdict: verdict, webKitReports: webKitReports);

    test('a request let through counts where it loads, never at the ask', () {
      expect(counts(before, verdict: const Allowed()), isFalse);
      expect(counts(issued, verdict: const Allowed()), isFalse);
    });

    test('a block made before the request went out counts, whichever list', () {
      expect(counts(before, verdict: dns), isTrue);
      expect(counts(before, verdict: abp), isTrue);
      expect(counts(before, verdict: abp, webKitReports: true), isTrue);
    });

    test('an issued request counts only as WebKit\'s filter lists stopped it', () {
      expect(counts(issued, verdict: abp), isTrue);
      expect(counts(issued, verdict: dnsAlsoAbp), isTrue);
      expect(counts(issued, verdict: const Redirect('data:,')), isTrue);
      expect(counts(issued, verdict: dns), isFalse,
          reason: 'the DNS list is not in WebKit\'s rule lists, so it went out');
    });

    test('where WebKit reports its blocks, an issued request is left to the report', () {
      expect(counts(issued, verdict: abp, webKitReports: true), isFalse);
      expect(counts(issued, verdict: dnsAlsoAbp, webKitReports: true), isFalse);
    });
  });

  group('PageReport.parse', () {
    test('reads each kind and refuses what is none', () {
      expect(
          PageReport.parse({'why': 'webkit', 'url': 'https://a.example/b'}),
          isA<WebKitBlocked>().having((r) => r.url, 'url', 'https://a.example/b'));
      expect(
          PageReport.parse({
            'why': 'failed',
            'url': 'https://a.example/i.png',
            'type': 'image',
            'issued': true,
          }),
          isA<PageSaw>().having((r) => r.request, 'request',
              (url: 'https://a.example/i.png', requestType: 'image', issued: true)));
      expect(PageReport.parse({'why': 'cached', 'url': 'https://a.example/'}), isNull,
          reason: 'a page report names its type and whether it was issued');
      expect(PageReport.parse({'why': 'other', 'url': 'https://a.example/'}), isNull);
      expect(PageReport.parse('https://a.example/'), isNull);
    });
  });

  group('BlockDecision.reported (CB-023)', () {
    test('a URL the DNS list names is DNS\'s, and the filter lists\' too', () {
      final r = BlockDecision.reported('https://t.example/p.gif',
          sourceUrl: 'https://site.example/',
          policy: _on,
          lists: _Lists(dnsHosts: {'t.example'}));
      expect(r?.verdict.source, BlockSource.dns);
      expect(r?.verdict.alsoAbp, isTrue);
    });

    test('else the filter lists\', under the first type a rule matches', () {
      final lists = _TypedLists(blocks: {('https://ads.example/b', 'xhr')});
      final r = BlockDecision.reported('https://ads.example/b',
          sourceUrl: 'https://site.example/', policy: _on, lists: lists);
      expect(r?.verdict.source, BlockSource.abp);
      expect(r?.query.requestType, 'xhr');
      expect(r?.query.sourceUrl, 'https://site.example/');
    });

    test('a URL no list names records nothing, so a forged report is dropped', () {
      expect(
          BlockDecision.reported('https://news.example/',
              sourceUrl: 'https://site.example/', policy: _on, lists: _Lists()),
          isNull);
    });

    test('with content blocking off, only DNS can claim it', () {
      final r = BlockDecision.reported('https://ads.example/b',
          sourceUrl: 'https://site.example/',
          policy: (dnsLevel: 3, contentBlock: false),
          lists: _TypedLists(blocks: {('https://ads.example/b', 'xhr')}));
      expect(r, isNull);
    });
  });
}

/// Filter lists whose rules each match one URL as one request type.
class _TypedLists extends _Lists {
  _TypedLists({required this.blocks});

  final Set<(String, String)> blocks;

  @override
  bool abpBlocksUrl(String url,
          {required String sourceUrl, required String requestType}) =>
      blocks.contains((url, requestType));
}
