// WEBEXT-005, WEBEXT-006 and WEBEXT-010 at the effect level, where WebKit
// runs web extensions (iOS 18.4+, macOS 15.4+): an extension written here, a
// content script that marks the page with what it last stored and stores the
// page's tag, runs as the fork attaches it to a container's webviews.
//
// - It runs on the host it was granted and on no other, nor where it is not
//   attached (WEBEXT-005).
// - What it stores is the container's: a second webview of the container,
//   as a nested screen is, reads it, and another container's never does
//   (WEBEXT-006, WEBEXT-010). One controller shared by every container is
//   the planted mistake this catches (design D2).
// - Deleting the container deletes what it stored (WEBEXT-006).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/apple_os_floor.dart';

import 'fixture_server.dart';

const _probe = '''
(async () => {
  const tag = new URL(location.href).searchParams.get('tag');
  const stored = await browser.storage.local.get('seen');
  await browser.storage.local.set({ seen: tag });
  document.documentElement.setAttribute('data-ws-ext', stored.seen || 'none');
})();
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final runs = hostRunsWebExtensions;
  final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  String container(String name) => 'ws-webext-$name-$stamp';
  final used = <String>{};

  late HttpServer server;
  late Directory folder;
  late inapp.WebExtensionAttach attach;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(
      server,
      onEvent: (request) {
        final res = request.response
          ..headers.set('Cache-Control', 'no-store')
          ..headers.contentType = ContentType.html
          ..write('<!doctype html><html><body>page</body></html>');
        unawaited(res.close());
      },
    );
    folder = await Directory.systemTemp.createTemp('ws-webext-');
    await File('${folder.path}/manifest.json').writeAsString(
      jsonEncode({
        'manifest_version': 3,
        'name': 'Webspace probe',
        'version': '1.0',
        'permissions': ['storage'],
        'host_permissions': ['*://*/*'],
        'content_scripts': [
          {
            'matches': ['*://*/*'],
            'js': ['probe.js'],
            'run_at': 'document_end',
          },
        ],
      }),
    );
    await File('${folder.path}/probe.js').writeAsString(_probe);
    attach = inapp.WebExtensionAttach(
      persistent: true,
      inspectable: false,
      contexts: [
        inapp.WebExtensionContextSpec(
          id: 'ws-probe',
          path: folder.path,
          revision: '1',
          grantedMatchPatterns: ['http://127.0.0.1/*'],
          grantedPermissions: ['storage'],
        ),
      ],
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    for (final name in used) {
      await inapp.ContainerController.instance().deleteContainer(name);
    }
    await folder.delete(recursive: true);
  });

  String page(String host, {required String tag}) =>
      'http://$host:${server.port}/page?tag=$tag';

  /// What the probe marks a page of [url] with in a webview of [name], the
  /// probe attached or not; null when it ran on none. Read once the page has
  /// loaded and the probe has had time to run.
  Future<String?> markOn(
    WidgetTester tester, {
    required String name,
    required String url,
    required bool attached,
  }) async {
    used.add(name);
    final created = Completer<inapp.InAppWebViewController>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: inapp.InAppWebView(
            key: UniqueKey(),
            initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(url)),
            initialSettings: inapp.InAppWebViewSettings(
              containerId: name,
              webExtensions: attached ? attach : null,
            ),
            onWebViewCreated: created.complete,
          ),
        ),
      ),
    );
    final view = await created.future;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    String? mark;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      DateTime? loaded;
      while (DateTime.now().isBefore(deadline)) {
        final found = await view.evaluateJavascript(
          source:
              "[document.readyState, "
              "document.documentElement.getAttribute('data-ws-ext')]",
        );
        if (found case [final String state, final String? seen]) {
          if (seen != null) {
            mark = seen;
            return;
          }
          if (state == 'complete') loaded ??= DateTime.now();
        }
        if (loaded case final at?
            when DateTime.now().difference(at) > const Duration(seconds: 5)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    });
    return mark;
  }

  testWidgets('WEBEXT-005 an attached extension runs on the host it was '
      'granted, and not on another host or where it is not attached', (
    tester,
  ) async {
    final site = container('grants');
    expect(
      await markOn(
        tester,
        name: site,
        url: page('127.0.0.1', tag: 'a1'),
        attached: true,
      ),
      'none',
      reason: 'the probe did not run on the host it was granted',
    );
    expect(
      await markOn(
        tester,
        name: site,
        url: page('localhost', tag: 'a2'),
        attached: true,
      ),
      isNull,
      reason: 'the probe ran on a host it was not granted',
    );
    expect(
      await markOn(
        tester,
        name: container('plain'),
        url: page('127.0.0.1', tag: 'p1'),
        attached: false,
      ),
      isNull,
      reason: 'the probe ran in a webview it was not attached to',
    );
  }, skip: !runs);

  testWidgets('WEBEXT-006 WEBEXT-010 what it stores is its container\'s, '
      'read by the container\'s next webview and by no other container\'s', (
    tester,
  ) async {
    final site = container('own');
    final other = container('other');
    expect(
      await markOn(
        tester,
        name: site,
        url: page('127.0.0.1', tag: 'a1'),
        attached: true,
      ),
      'none',
    );
    expect(
      await markOn(
        tester,
        name: site,
        url: page('127.0.0.1', tag: 'a2'),
        attached: true,
      ),
      'a1',
      reason: 'a webview of the same container did not read what it stored',
    );
    expect(
      await markOn(
        tester,
        name: other,
        url: page('127.0.0.1', tag: 'b1'),
        attached: true,
      ),
      'none',
      reason: 'another container read what this one stored',
    );
  }, skip: !runs);

  testWidgets('WEBEXT-006 deleting the container deletes what it stored', (
    tester,
  ) async {
    final site = container('deleted');
    expect(
      await markOn(
        tester,
        name: site,
        url: page('127.0.0.1', tag: 'a1'),
        attached: true,
      ),
      'none',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    // The webview lets go of the store only once a frame disposes its
    // platform view, so frames run between the attempts.
    var deleted = false;
    for (var attempt = 0; attempt < 40 && !deleted; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() async {
        deleted = await inapp.ContainerController.instance().deleteContainer(
          site,
        );
        if (!deleted) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      });
    }
    // The extension's records go after the store, on the main queue.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    expect(deleted, isTrue, reason: 'the container was never deleted');
    expect(
      await markOn(
        tester,
        name: site,
        url: page('127.0.0.1', tag: 'a2'),
        attached: true,
      ),
      'none',
      reason: 'what it stored outlived its container',
    );
  }, skip: !runs);
}
