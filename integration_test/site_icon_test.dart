// Site icon from the webview (ICON-009/010/011) against a real Android
// System WebView.
//
// `onReceivedIcon` exists only in Android WebView: Chromium's IconHelper
// downloads every `rel=icon` candidate once `WebIconDatabase.open` has set
// the process-wide flag, and hands each one over as a bare bitmap. That is
// the path this pins, end to end: SiteIconPlugin.kt turns it on, the fork
// forwards the PNG, SiteIconEngine decides what the site's icon is, and the
// icon-link watcher reports a page that swaps its icon after load. Which
// requests Blink starts is also pinned against desktop Chrome by
// test/browser/icon_link_watcher_real.test.js; which icon WebView delivers
// can only be seen here.
//
// Every icon is a solid colour, so the test reads back which one was taken
// from its pixels rather than trusting its size alone. The fixture server
// logs each request, which is how a negative case shows the icon was
// downloaded (so the callback fired) and then refused.
//
// Android only; the desktop integration loops skip this file, and it runs
// in the emulator job via scripts/run_android_site_icon_tests.sh.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/site_icon_engine.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';

class _Icon {
  const _Icon(this.size, this.r, this.g, this.b, [this.delayMs = 0]);

  final int size;
  final int r;
  final int g;
  final int b;
  final int delayMs;

  Uint8List png() {
    final image = img.Image(width: size, height: size);
    img.fill(image, color: img.ColorRgb8(r, g, b));
    return Uint8List.fromList(img.encodePng(image));
  }
}

// The multi-size page's icons finish downloading 32, then 192, then 16.
const Map<String, _Icon> _icons = {
  '/multi/32.png': _Icon(32, 0, 0, 255),
  '/multi/192.png': _Icon(192, 0, 255, 0, 600),
  '/multi/16.png': _Icon(16, 255, 0, 0, 1200),
  '/badge/a.png': _Icon(48, 0, 128, 255),
  '/badge/b.png': _Icon(96, 255, 0, 255),
  '/offsite.png': _Icon(64, 255, 128, 0),
  '/favicon.ico': _Icon(64, 0, 200, 100),
};

String _page(String head, [String body = '']) =>
    '<!doctype html><html><head>$head</head><body>site$body</body></html>';

final Map<String, String> _pages = {
  '/multi': _page(
    '<link rel="icon" sizes="16x16" href="/multi/16.png">'
    '<link rel="icon" sizes="32x32" href="/multi/32.png">'
    '<link rel="icon" sizes="192x192" href="/multi/192.png">',
  ),
  // The badge is larger than the icon it replaces, so only the watcher
  // keeps it out: by size alone the engine would take it.
  '/badge': _page(
    '<link rel="icon" href="/badge/a.png">',
    '<script>addEventListener("load", function() {'
        ' setTimeout(function() {'
        '  document.querySelector("link[rel=icon]").href = "/badge/b.png";'
        ' }, 2500);'
        '});</script>',
  ),
  '/offsite': _page('<link rel="icon" href="/offsite.png">'),
  '/plain': _page(''),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  final requested = <String>[];

  setUpAll(() async {
    // Any address, so the same server answers as 127.0.0.2: a second host
    // with no DNS involved.
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    port = server.port;
    listenFixture(server, (request) async {
      final path = request.uri.path;
      requested.add('${request.requestedUri.host}$path');
      final response = request.response;
      final icon = _icons[path];
      if (icon != null) {
        if (icon.delayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: icon.delayMs));
        }
        response
          ..headers.contentType = ContentType('image', 'png')
          ..headers.set('Cache-Control', 'no-store')
          ..add(icon.png());
      } else if (path == '/redirect') {
        response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', 'http://127.0.0.2:$port/offsite');
      } else if (_pages[path] != null) {
        response
          ..headers.contentType = ContentType.html
          ..write(_pages[path]);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('site_icon_test: $message');
  }

  String describe(SiteIcon icon) {
    final decoded = img.decodePng(icon.png);
    final pixel = decoded?.getPixel(icon.width ~/ 2, icon.height ~/ 2);
    return '${icon.width}x${icon.height}'
        '@${pixel?.r},${pixel?.g},${pixel?.b}';
  }

  String expected(String path) {
    final icon = _icons[path]!;
    return '${icon.size}x${icon.size}@${icon.r},${icon.g},${icon.b}';
  }

  /// Mount a site webview on [path] and collect what the engine accepted.
  /// Waits until [done] holds (or [timeout]), then [settle] more so an icon
  /// that should be refused has time to arrive and be refused.
  Future<List<String>> mount(
    WidgetTester tester,
    String path, {
    required bool Function(List<String> accepted) done,
    Duration timeout = const Duration(seconds: 45),
    Duration settle = const Duration(seconds: 4),
  }) async {
    final accepted = <String>[];
    final url = 'http://127.0.0.1:$port$path';
    final key = ValueKey('site-icon-$path');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 480,
          child: WebViewFactory.createWebView(
            config: WebViewConfig(
              key: key,
              initialUrl: url,
              httpsUpgradeEnabled: false,
              clearUrlEnabled: false,
              dnsBlockEnabled: false,
              contentBlockEnabled: false,
              trackingProtectionEnabled: false,
              localCdnEnabled: false,
              siteIcon: SiteIconTarget(
                siteUrl: url,
                onIcon: (icon) => accepted.add(describe(icon)),
              ),
            ),
            onControllerCreated: (_) {},
          ),
        ),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline) && !done(accepted)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await Future<void>.delayed(settle);
    });
    log('$path accepted=$accepted requested=$requested');
    return accepted;
  }

  testWidgets('keeps the largest of several icons, whatever order they land in',
      (tester) async {
    requested.clear();
    final accepted = await mount(tester, '/multi',
        done: (a) => a.contains(expected('/multi/192.png')));
    expect(requested, contains('127.0.0.1/multi/16.png'),
        reason: 'WebView downloads every rel=icon candidate');
    // 32 lands first and is taken even when it beats onLoadStop: this is the
    // webview's first page, so no other page's icon can be in flight. 192
    // replaces it; 16 lands last and is under the floor.
    expect(accepted,
        [expected('/multi/32.png'), expected('/multi/192.png')]);
  }, skip: !Platform.isAndroid);

  testWidgets('ignores the badge a page swaps in after load', (tester) async {
    requested.clear();
    final accepted = await mount(tester, '/badge',
        done: (a) => requested.contains('127.0.0.1/badge/b.png'));
    expect(requested, contains('127.0.0.1/badge/b.png'),
        reason: 'the swap never started a new icon round');
    expect(accepted, [expected('/badge/a.png')]);
  }, skip: !Platform.isAndroid);

  testWidgets('takes nothing from a page on another host', (tester) async {
    requested.clear();
    final accepted = await mount(tester, '/redirect',
        done: (_) => requested.contains('127.0.0.2/offsite.png'));
    expect(requested, contains('127.0.0.2/offsite.png'),
        reason: 'the other host never had its icon downloaded');
    expect(accepted, isEmpty);
  }, skip: !Platform.isAndroid);

  testWidgets('takes /favicon.ico when the page declares no icon',
      (tester) async {
    requested.clear();
    final accepted = await mount(tester, '/plain',
        done: (a) => a.isNotEmpty);
    expect(accepted, [expected('/favicon.ico')]);
  }, skip: !Platform.isAndroid);
}
