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
    test('a host both lists block counts against DNS, and ABP is not asked',
        () {
      final lists = _Lists(dnsHosts: {'t.example'}, abpHosts: {'t.example'});
      final v = BlockDecision.decide(_url('https://t.example/x'),
          policy: _on, lists: lists);
      expect(v, isA<Blocked>());
      expect(v.source, BlockSource.dns);
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
}
