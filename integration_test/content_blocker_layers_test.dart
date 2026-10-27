// Each layer of the content blocker, in a site's webview built by the app's
// own factory, on a live engine. One fixture page carries a target for each
// layer, all named by one local filter list:
//
//   * an HTML-parsed <script src>: only WebKit's content rule lists stop it
//     before it is sent (CB-020); the page interceptor never sees it
//   * a relative fetch() and a script the page appends by a relative src: the
//     page interceptor, which matches the URL the page resolves them to
//   * a site-specific hide: the early stylesheet at document start
//   * a generic class hide: the generic cosmetic scan's first pass
//   * a generic class on an element added after load: the scan's observer
//   * a `:has-text()` rule: the procedural shim
//
// The page also runs with the rule lists withheld, so the page interceptor is
// held on its own. Every verdict is logged before any is asserted, so one run
// names every layer that fails.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/content_rule_lists.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/filter_list_id.dart';
import 'package:webspace/settings/site_ids.dart';

import 'bare_site.dart';
import 'fixture_server.dart';
import 'helpers/ui.dart';

const _rules = '''
/wsprobe-ad/*
localhost##.ws-specific-ad
##.ws-generic-ad
##.ws-generic-late
localhost#?#.ws-card:has-text(Sponsored)
''';

const _page = '''
<!doctype html><html><head><title>probe</title>
<script src="/wsprobe-ad/parsed.js"></script>
</head><body>
<div id="specific" class="ws-specific-ad">specific</div>
<div id="generic" class="ws-generic-ad">generic</div>
<div id="proc" class="ws-card">Sponsored thing</div>
<div id="control">control</div>
<script>
fetch('/wsprobe-ad/fetched').catch(function() {});
var s = document.createElement('script');
s.src = '/wsprobe-ad/dynamic.js';
document.head.appendChild(s);
setTimeout(function() {
  var d = document.createElement('div');
  d.id = 'late';
  d.className = 'ws-generic-late';
  d.textContent = 'late';
  document.body.appendChild(d);
}, 1500);
</script>
</body></html>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(bareSetUp);

  late HttpServer server;
  late int port;
  late FilterListId list;
  final requested = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[blocker-layers] $m');
  }

  setUpAll(() async {
    await ContentBlockerService.instance.initialize(
      native: WebInterceptNative.initialize(),
    );
    await DnsBlockService.instance.initialize();
    list = await ContentBlockerService.instance.addLocalList(
      'blocker layers probe',
      rules: _rules,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    listenFixture(
      server,
      onEvent: (req) {
        requested.add(req.uri.path);
        final res = req.response..headers.set('Cache-Control', 'no-store');
        if (req.uri.path.endsWith('.js')) {
          res
            ..headers.contentType = ContentType('application', 'javascript')
            ..write('window.__wsProbeRan = (window.__wsProbeRan || 0) + 1;');
        } else {
          res
            ..headers.contentType = ContentType.html
            ..write(_page);
        }
        unawaited(res.close());
      },
    );
  });

  tearDownAll(() async {
    await ContentBlockerService.instance.removeList(list);
    await server.close(force: true);
  });

  Future<WebViewController> mount(
    WidgetTester tester, {
    required String url,
  }) async {
    final ctrl = Completer<WebViewController>();
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
                  siteId: SiteId('blocker-layers'),
                  adjust: (site) => site.contentBlockEnabled = true,
                ),
                initialUrl: url,
              ),
              onControllerCreated: (c) {
                if (!ctrl.isCompleted) ctrl.complete(c);
              },
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return ctrl.future;
  }

  /// Each target's display and how many of the page's scripts ran.
  Future<Map<String, String>> probe(
    WidgetTester tester, {
    required WebViewController c,
  }) async {
    final out = <String, String>{};
    await tester.runAsync(() async {
      for (final id in ['specific', 'generic', 'proc', 'late', 'control']) {
        out[id] =
            '${await c.evaluateJavascriptReturning("(function(){var e=document.getElementById('$id');"
            "return e ? getComputedStyle(e).display : 'absent';})()")}';
      }
      out['ran'] =
          '${await c.evaluateJavascriptReturning('window.__wsProbeRan || 0')}';
    });
    return out;
  }

  final hasStore = MethodChannelContentRuleListStore.here != null;
  for (final ruleLists in [false, if (hasStore) true]) {
    testWidgets('each blocker layer reaches the page, CB-003 CB-004 CB-005 '
        'CB-020 (content rule lists ${ruleLists ? 'on' : 'withheld'})', (
      tester,
    ) async {
      final blocker = ContentBlockerService.instance;
      blocker.debugWithholdRuleLists = !ruleLists;
      addTearDown(() => blocker.debugWithholdRuleLists = false);
      const waitReal = RealWait(interval: Duration(milliseconds: 300));
      if (ruleLists) {
        // A new rule set compiles after the rebuild returns.
        await waitReal(
          tester,
          done: () => blocker.contentRuleListIdentifiers.isNotEmpty,
          label: 'rule lists compiled',
        );
      }
      log(
        'rule lists: '
        '${blocker.contentRuleListIdentifiers}',
      );
      requested.clear();
      final url =
          'http://localhost:$port/probe-${ruleLists ? 'lists' : 'withheld'}';
      final c = await mount(tester, url: url);
      await waitReal(
        tester,
        done: () => requested.any((p) => p.startsWith('/probe')),
        label: 'page',
      );
      // The late element lands 1.5 s after the page; the scan debounces it.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      final seen = await probe(tester, c: c);
      log('requested: $requested');
      seen.forEach((k, v) => log('$k = $v'));

      expect(seen['control'], 'block', reason: 'the page never rendered');
      expect(seen['specific'], 'none', reason: 'early stylesheet');
      expect(seen['generic'], 'none', reason: 'generic scan');
      expect(seen['late'], 'none', reason: 'generic scan observer');
      expect(seen['proc'], 'none', reason: 'procedural shim');
      expect(
        requested,
        isNot(contains('/wsprobe-ad/fetched')),
        reason: 'page interceptor: relative fetch',
      );
      expect(
        requested,
        isNot(contains('/wsprobe-ad/dynamic.js')),
        reason: 'page interceptor: appended script',
      );
      if (ruleLists) {
        expect(
          requested,
          isNot(contains('/wsprobe-ad/parsed.js')),
          reason: 'content rule lists: parsed script',
        );
      }
    });
  }
}
