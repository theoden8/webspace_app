// Ground truth for the block counts (CB-012, DNS-014): a page whose every
// request is declared below, served from a loopback server that logs what
// arrives, its icon inline so the engine fetches none of its own. Each
// request counts once in the site's stats, so:
//
//   allowed == the requests that arrived
//   blocked == the requests made less those that arrived, each against the
//              list that counts it (DNS first); a DNS block the filter lists
//              also stop counts for both lists but once in the total
//
// The page and the expected counts are both read off the declaration, and
// the server's log checks the declaration itself: what it says loads
// arrived, and nothing it says is blocked did. The DNS list names the
// loopback address, so a DNS-blocked request would have reached the same
// server had it gone out. Every count is logged before any is asserted.
//
// Runs on a live engine in a site's webview built by the app's own factory:
// Android counts in its native interceptor, the WebKit engines in the page
// interceptor and the resource observer (with the content rule lists on, as
// a site runs them).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/content_rule_lists.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/settings/filter_list_id.dart';
import 'package:webspace/settings/site_ids.dart';

import 'bare_site.dart';
import 'fixture_server.dart';
import 'helpers/ui.dart';

/// What happens to a request of the page.
enum _Fate { loads, dns, abp, dnsAlsoAbp }

/// How the page makes a request.
enum _How { parsedScript, stylesheet, image, fetch }

/// One request the page makes: [dnsHost] sends it to the loopback address
/// the DNS list names, else to the page's own host.
typedef _Request = ({_How how, String path, bool dnsHost, _Fate fate});

const _rules = '''
/wsacct-ad/*
/wsboth/*
''';

/// The page's requests besides its document, in the order it makes them. The
/// DNS-host fetches run one after another, so the page interceptor's host
/// cache answers the later ones.
const List<_Request> _requests = [
  (how: _How.parsedScript, path: '/wsacct-ad/parsed.js', dnsHost: false, fate: _Fate.abp),
  (how: _How.stylesheet, path: '/ok/style.css', dnsHost: false, fate: _Fate.loads),
  (how: _How.image, path: '/ok/a.gif', dnsHost: false, fate: _Fate.loads),
  (how: _How.image, path: '/ok/b.gif', dnsHost: false, fate: _Fate.loads),
  (how: _How.fetch, path: '/ok/data', dnsHost: false, fate: _Fate.loads),
  (how: _How.fetch, path: '/wsacct-ad/f0', dnsHost: false, fate: _Fate.abp),
  (how: _How.fetch, path: '/wsacct-ad/f1', dnsHost: false, fate: _Fate.abp),
  (how: _How.fetch, path: '/wsacct-ad/f2', dnsHost: false, fate: _Fate.abp),
  (how: _How.fetch, path: '/x', dnsHost: true, fate: _Fate.dns),
  (how: _How.fetch, path: '/y', dnsHost: true, fate: _Fate.dns),
  (how: _How.fetch, path: '/wsboth/z', dnsHost: true, fate: _Fate.dnsAlsoAbp),
];

const _pagePath = '/acct';
const _dnsHost = '127.0.0.1';

/// Where the counts are known not to add up yet, each with its reason. Only
/// shrinks: a gap closed is deleted here, in the change that closes it.
const Map<String, String> _gaps = {};

String _page({required int port}) {
  String url(_Request r) =>
      r.dnsHost ? 'http://$_dnsHost:$port${r.path}' : r.path;
  final head = StringBuffer();
  final body = StringBuffer();
  final fetches = <String>[];
  for (final r in _requests) {
    switch (r.how) {
      case _How.parsedScript:
        head.writeln('<script src="${url(r)}"></script>');
      case _How.stylesheet:
        head.writeln('<link rel="stylesheet" href="${url(r)}">');
      case _How.image:
        body.writeln('<img src="${url(r)}">');
      case _How.fetch:
        fetches.add(url(r));
    }
  }
  final chain = fetches
      .map((u) => ".then(function(){return fetch('$u').catch(function(){});})")
      .join();
  return '<!doctype html><html><head><title>accounting</title>\n'
      '<link rel="icon" href="data:,">\n$head'
      '</head><body>\n$body<script>Promise.resolve()$chain'
      '.then(function(){window.__wsAcctDone=true;});</script>\n</body></html>';
}

const _gif = [
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
  0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
  0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(bareSetUp);

  final site = SiteId('block-accounting');
  late HttpServer server;
  late int port;
  late FilterListId list;
  late List<String> listsBefore;
  final arrived = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[block-accounting] $m');
  }

  setUpAll(() async {
    final native = WebInterceptNative.initialize();
    await ContentBlockerService.instance.initialize(native: native);
    final dns = await DnsBlockService.instance.initialize();
    await dns.mirrorInto(native);
    DnsBlockService.instance.loadDomainsFromString(_dnsHost);
    listsBefore = ContentBlockerService.instance.contentRuleListIdentifiers;
    list = await ContentBlockerService.instance.addLocalList(
      'block accounting probe',
      rules: _rules,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    listenFixture(
      server,
      onEvent: (req) {
        final path = req.uri.path;
        final res = req.response..headers.set('Cache-Control', 'no-store');
        arrived.add('${req.headers.host?.split(':').first}$path');
        if (path.endsWith('.js')) {
          res
            ..headers.contentType = ContentType('application', 'javascript')
            ..write('window.__wsAcctRan = 1;');
        } else if (path.endsWith('.css')) {
          res
            ..headers.contentType = ContentType('text', 'css')
            ..write('body { margin: 0; }');
        } else if (path.endsWith('.gif')) {
          res
            ..headers.contentType = ContentType('image', 'gif')
            ..add(_gif);
        } else if (path == _pagePath) {
          res
            ..headers.contentType = ContentType.html
            ..write(_page(port: port));
        } else {
          res
            ..headers.contentType = ContentType.text
            ..write('ok');
        }
        unawaited(res.close());
      },
    );
  });

  tearDownAll(() async {
    await ContentBlockerService.instance.removeList(list);
    DnsBlockService.instance.loadDomainsFromString('');
    await server.close(force: true);
  });

  testWidgets('every request counts once, and the counts are what arrived '
      '(CB-012, DNS-014)', (tester) async {
    const waitReal = RealWait(interval: Duration(milliseconds: 300));
    final blocker = ContentBlockerService.instance;
    if (MethodChannelContentRuleListStore.here != null) {
      await waitReal(
        tester,
        done: () {
          final now = blocker.contentRuleListIdentifiers;
          return now.isNotEmpty && !listEquals(now, listsBefore);
        },
        label: 'rule lists compiled',
      );
    }
    DnsBlockService.instance.clearStatsForSite(site);
    arrived.clear();

    final url = 'http://localhost:$port$_pagePath';
    final made = 1 + _requests.length;
    final stats = DnsBlockService.instance.statsForSite(site);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                cacheFirst: false,
                hooks: bareHooks(),
                posture: barePosture(
                  url,
                  siteId: site,
                  adjust: (s) => s
                    ..contentBlockEnabled = true
                    ..dnsBlockEnabled = true,
                ),
                initialUrl: url,
              ),
              onControllerCreated: (_) {},
            ),
          ),
        ),
      ),
    );
    await waitReal(
      tester,
      done: () => stats.total >= made,
      label: 'every request counted',
    );
    // Batches still on their way (a drain, the observer's next flush) land
    // in this window, so a count past the truth shows too.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );

    String target(_Request r) =>
        '${r.dnsHost ? _dnsHost : 'localhost'}${r.path}';
    int declared(Set<_Fate> fates) =>
        _requests.where((r) => fates.contains(r.fate)).length;

    log('arrived: $arrived');
    log('allowed=${stats.allowed} blocked=${stats.blocked} '
        'dns=${stats.blockedByDns} abp=${stats.blockedByAbp} '
        'abpReach=${stats.stoppedBy(BlockSource.abp)} '
        'dnsAlsoAbp=${stats.blockedByDnsAlsoAbp}');
    for (final e in stats.log) {
      log('  ${e.source?.name ?? 'allowed'}'
          '${e.alsoAbp ? '+abp' : ''} ${e.matched?.url ?? e.domain}');
    }
    log('gaps: $_gaps');

    // The declaration is the truth: what it says loads arrived, and what it
    // says is blocked did not.
    for (final r in _requests) {
      expect(arrived.contains(target(r)), r.fate == _Fate.loads,
          reason: '${target(r)} is declared ${r.fate.name}');
    }
    expect(arrived, contains('localhost$_pagePath'));
    expect(
        arrived.where((a) =>
            a != 'localhost$_pagePath' && !_requests.map(target).contains(a)),
        isEmpty,
        reason: 'nothing arrives the page did not declare: its icon is inline');

    // The counts are the truth.
    expect(stats.allowed, arrived.length,
        reason: 'allowed counts each request that went out, once');
    expect(stats.blocked, made - arrived.length,
        reason: 'blocked counts each request that did not go out, once');
    expect(stats.blockedByDns, declared({_Fate.dns, _Fate.dnsAlsoAbp}));
    expect(stats.blockedByAbp, declared({_Fate.abp}));
    expect(stats.blockedByDnsAlsoAbp, declared({_Fate.dnsAlsoAbp}));
    expect(stats.stoppedBy(BlockSource.abp),
        declared({_Fate.abp, _Fate.dnsAlsoAbp}));
  });
}
