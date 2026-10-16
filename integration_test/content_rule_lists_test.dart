// CB-020 at the effect level, on every host with a content rule list store:
// a rule set converted by adblock-rust and compiled once into this host's
// store is attached by name to a webview created after it, and that webview's
// request for the blocked script never reaches the server, before and after
// an update of its settings (which, in the stock plugin, dropped every list).
// A webview created without the name fetches the same script first, so the
// missing request is the list, not a page that never loaded here.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_rule_list_engine.dart';
import 'package:webspace/services/content_rule_lists.dart';

import 'fixture_server.dart';

final _key = RuleSetKey.of('c0de' * 16);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final store = MethodChannelContentRuleListStore.here;

  late HttpServer server;
  late String base;
  final requested = <String>[];

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(
      server,
      onEvent: (request) {
        requested.add(request.uri.toString());
        final res = request.response..headers.set('Cache-Control', 'no-store');
        if (request.uri.path == '/blocked.js') {
          res
            ..headers.contentType = ContentType('application', 'javascript')
            ..write("window.__wsProbe = 'ran';");
        } else {
          final tag = request.uri.queryParameters['tag'];
          res
            ..headers.contentType = ContentType.html
            ..write(
              '<!doctype html><html><body>'
              '<script src="/blocked.js?tag=$tag"></script></body></html>',
            );
        }
        unawaited(res.close());
      },
    );
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() => server.close(force: true));

  /// Waits for the page tagged [tag] and reports whether its script request
  /// reached the server.
  Future<bool> fetchedScript(WidgetTester tester, {required String tag}) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!requested.contains('/page?tag=$tag') &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      // The page's own script request follows its document by milliseconds;
      // this is the window in which a list that failed to attach shows.
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    expect(
      requested,
      contains('/page?tag=$tag'),
      reason: 'the page itself never loaded',
    );
    return requested.contains('/blocked.js?tag=$tag');
  }

  /// Mounts a webview naming [identifiers] on the page tagged [tag].
  Future<inapp.InAppWebViewController> mount(
    WidgetTester tester, {
    required List<String> identifiers,
    required String tag,
  }) async {
    final created = Completer<inapp.InAppWebViewController>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: inapp.InAppWebView(
            key: ValueKey('rule-lists-$tag'),
            initialUrlRequest: inapp.URLRequest(
              url: inapp.WebUri('$base/page?tag=$tag'),
            ),
            initialSettings: inapp.InAppWebViewSettings(
              contentRuleListIdentifiers: identifiers,
            ),
            onWebViewCreated: created.complete,
          ),
        ),
      ),
    );
    return created.future;
  }

  testWidgets('a compiled set stops the request before it is sent', (
    tester,
  ) async {
    final lists = ContentRuleLists(
      store: store!,
      convert: AdblockEngine.contentRuleLists,
    );
    await tester.runAsync(() async {
      await lists.sync(wanted: null, rulesText: () async => '');
      await lists.sync(
        wanted: _key,
        rulesText: () async => '/blocked.js\$script\n',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (lists.identifiers.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    });
    expect(lists.identifiers, isNotEmpty, reason: 'the set never compiled');

    await mount(tester, identifiers: const [], tag: 'control');
    expect(await fetchedScript(tester, tag: 'control'), isTrue);

    final listed = await mount(
      tester,
      identifiers: lists.identifiers,
      tag: 'listed',
    );
    expect(await fetchedScript(tester, tag: 'listed'), isFalse);

    await tester.runAsync(() async {
      await listed.setSettings(
        settings: inapp.InAppWebViewSettings(
          contentRuleListIdentifiers: lists.identifiers,
          minimumFontSize: 2,
        ),
      );
      await listed.loadUrl(
        urlRequest: inapp.URLRequest(
          url: inapp.WebUri('$base/page?tag=after-settings'),
        ),
      );
    });
    expect(
      await fetchedScript(tester, tag: 'after-settings'),
      isFalse,
      reason: 'a settings update dropped the attached lists',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    final left = await tester.runAsync(() async {
      await lists.sync(wanted: null, rulesText: () async => '');
      return store.identifiers();
    });
    expect(
      [for (final raw in left!) ?RuleListId.parse(raw)],
      isEmpty,
      reason: 'turning the set off leaves none of ours in the store',
    );
  }, skip: store == null);
}
