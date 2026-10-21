// NESTED-004 end to end: a page's own script that navigates to another
// domain with no user gesture opens nothing (no nested screen, no browser,
// no other site) and the site keeps its address. The decision itself is
// tested in test/; this drives the platform's report of the gesture through
// WebViewModel.getWebView, the production wiring, on a real webview.
//
// The two domains are one loopback server under two names, 127.0.0.1 and
// localhost. The page first loads an image from the other name: the control
// that the other domain is reachable from this webview, so a hop that never
// arrives there is a decision and not a connection failure.
//
// Where the platform reports the main frame, the hop is cancelled before it
// is requested. On Linux it cannot (NESTED-013): a navigation that is not a
// link click loads in place and the URL-change check judges it, so the other
// domain is asked for the page while the site still keeps its address. The
// Linux arm pins that until WebKit's main-frame flag retires the inference.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'bare_site.dart';
import 'fixture_server.dart';
import 'helpers/ui.dart';

String _page({required String other}) => '''
<!doctype html><html><body>
<img src="$other/probe.png">
<script>
  window.addEventListener('load', function () {
    setTimeout(function () { location.href = '$other/landing'; }, 300);
  });
</script>
</body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(bareSetUp);

  late HttpServer server;
  late String home;
  final otherPaths = <String>[];

  setUpAll(() async {
    // anyIPv4, so both loopback names reach the one server.
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    home = 'http://127.0.0.1:${server.port}';
    final other = 'http://localhost:${server.port}';
    listenFixture(server, onEvent: (request) {
      if (request.headers.host == 'localhost') otherPaths.add(request.uri.path);
      final res = request.response..headers.contentType = ContentType.html;
      res.write(request.uri.path == '/page'
          ? _page(other: other)
          : '<!doctype html><html><body></body></html>');
      unawaited(res.close());
    });
  });

  tearDownAll(() async => server.close(force: true));

  testWidgets(
      'a script hop to another domain opens nothing and keeps the site '
      '(NESTED-004, NESTED-013)', (tester) async {
    final left = <String>[];
    final site = WebViewModel(
      siteId: SiteId('script-hop'),
      initUrl: '$home/page',
      name: 'Script hop',
      clearUrlEnabled: false,
      dnsBlockEnabled: false,
      contentBlockEnabled: false,
      trackingProtectionEnabled: false,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: site.getWebView(bareHooks(leaving: left.add), cacheFirst: false),
      ),
    ));
    await pumpFor(tester, total: const Duration(seconds: 2));
    const wait = RealWait(timeout: Duration(seconds: 45));

    expect(await wait(tester, done: () => otherPaths.contains('/probe.png')),
        isTrue,
        reason: 'the page loads an image from the other domain first; '
            'without it a hop that never arrives proves nothing');

    Future<String?> shownHost() async =>
        (await tester.runAsync(() async => site.controller?.getUrl()))?.host;

    if (hostIsLinux) {
      expect(await wait(tester, done: () => otherPaths.contains('/landing')),
          isTrue,
          reason: 'not a link click, so not taken as the page itself: it '
              'loads in place (NESTED-013)');
      var host = await shownHost();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (host != 'localhost' && DateTime.now().isBefore(deadline)) {
        await pumpFor(tester, total: const Duration(milliseconds: 500));
        host = await shownHost();
      }
      expect(host, 'localhost', reason: 'the hop committed in the webview');
      // Its load's URL change has had time to be judged.
      await pumpFor(tester, total: const Duration(seconds: 2));
    } else {
      await pumpFor(tester, total: const Duration(seconds: 5));
      expect(otherPaths, isNot(contains('/landing')),
          reason: 'a gesture-less hop of the main frame is cancelled before '
              'it is requested');
      expect(await shownHost(), '127.0.0.1');
    }

    expect(left, isEmpty,
        reason: 'no nested screen, browser or other site for a hop without '
            'a gesture');
    expect(site.currentUrl, '$home/page',
        reason: 'the site keeps its own address');
  });
}
