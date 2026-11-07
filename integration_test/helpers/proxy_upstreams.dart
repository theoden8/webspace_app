import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/webspace_model.dart';

import '../fixture_server.dart';

/// A minimal upstream HTTP proxy that records what reached it.
///
/// Speaks just enough to answer the relay or the WebView: absolute-form
/// requests get a canned 200, `CONNECT` gets a 200 then the socket is
/// dropped. The destination never has to exist: what is under test is
/// which upstream a site's traffic reached, not whether the page rendered.
///
/// The app's own requests for a site (its icon, its title) go to the site's
/// proxy from Dart, whatever its WebView does, so a request reaching an
/// upstream says nothing about the WebView. [navigations] does: Chromium
/// sends `Upgrade-Insecure-Requests: 1` with every navigation, and the
/// app's Dart clients never send it.
class RecordingUpstream {
  final ServerSocket _server;
  final String label;
  final List<String> requestLines = [];
  final List<String> credentials = [];

  /// The request lines of the WebView navigations that reached this
  /// upstream, told from the app's own requests by the header only a
  /// navigation carries.
  final List<String> navigations = [];

  /// Each request line with when it arrived, a navigation marked, for a
  /// failure's timeline.
  final List<(DateTime, String)> timeline = [];

  RecordingUpstream._(this._server, {required this.label}) {
    listenFixture(
      _server,
      onEvent: (socket) {
        final buffer = StringBuffer();
        late StreamSubscription sub;
        sub = socket
            .handleError(
              (Object _) => socket.destroy(),
              test: (e) => e is SocketException,
            )
            .listen((data) {
              buffer.write(latin1.decode(data));
              if (!buffer.toString().contains('\r\n\r\n')) return;
              final at = DateTime.now();
              final lines = buffer.toString().split('\r\n');
              requestLines.add(lines.first);
              var navigation = false;
              for (final line in lines.skip(1)) {
                final header = line.toLowerCase();
                if (header.startsWith('proxy-authorization:')) {
                  credentials.add(line.substring(line.indexOf(':') + 1).trim());
                }
                if (header.startsWith('upgrade-insecure-requests:')) {
                  navigations.add(lines.first);
                  navigation = true;
                }
              }
              timeline.add((at, navigation ? '${lines.first} (navigation)' : lines.first));
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n'
                'Content-Length: 13\r\nConnection: close\r\n\r\n'
                '<html></html>',
              );
              unawaited(sub.cancel());
              unawaited(socket.flush().then((_) => socket.destroy()));
            }, cancelOnError: true);
      },
    );
  }

  static Future<RecordingUpstream> start(String label) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return RecordingUpstream._(server, label: label);
  }

  int get port => _server.port;

  /// Whether every request that reached this upstream was for [host].
  bool onlyFor(String host) => requestLines.every((l) => l.contains(host));

  Future<void> close() => _server.close();
}

/// Every request each upstream saw, merged with the app's own proxy,
/// unload and webview log lines, in the order they happened.
String upstreamTimeline({
  required RecordingUpstream a,
  required RecordingUpstream b,
}) {
  const tags = {
    'Proxy',
    'ProxyRelay',
    'SiteUnload',
    'WebView',
    'WebViewLifecycle',
    'SiteIcon',
    'Startup',
    'Test',
  };
  final events = <(DateTime, String)>[
    for (final (at, line) in a.timeline) (at, 'upstream A <- $line'),
    for (final (at, line) in b.timeline) (at, 'upstream B <- $line'),
    for (final e in LogService.instance.allEntriesMerged)
      if (tags.contains(e.tag)) (e.timestamp, '[${e.tag}] ${e.message}'),
  ]..sort((x, y) => x.$1.compareTo(y.$1));
  return [
    for (final (at, what) in events) '${at.toIso8601String()} $what',
  ].join('\n');
}

/// Open the site named [name] from the drawer, as a user would, then give
/// its webview twelve seconds to issue its traffic.
Future<void> openSiteFromDrawer(
  WidgetTester tester, {
  required String name,
}) async {
  // Re-open the drawer each time: activating a site closes it.
  for (var attempt = 0; attempt < 3; attempt++) {
    if (find.byType(Drawer).evaluate().isNotEmpty) break;
    final menuIcon = find.byIcon(Icons.menu);
    if (menuIcon.evaluate().isNotEmpty) {
      await tester.tap(menuIcon.first);
    } else {
      for (final element in find.byType(Scaffold).evaluate()) {
        final state = tester.state<ScaffoldState>(
          find.byWidget(element.widget as Scaffold),
        );
        if (state.hasDrawer) {
          state.openDrawer();
          break;
        }
      }
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  final drawer = find.byType(Drawer);
  if (drawer.evaluate().isNotEmpty &&
      find
          .descendant(of: drawer, matching: find.text(name))
          .evaluate()
          .isEmpty) {
    final allTile = find.byKey(const ValueKey(WebspaceId.all));
    if (allTile.evaluate().isNotEmpty) {
      await tester.tap(allTile);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
  }

  // Scoped to the drawer and `findsWidgets`: the active site's name also
  // renders in the app bar, so a bare finder matches twice.
  final scoped = find.byType(Drawer);
  final target = scoped.evaluate().isNotEmpty
      ? find.descendant(of: scoped, matching: find.text(name))
      : find.text(name);
  expect(target, findsWidgets, reason: '$name should be in the drawer');
  await tester.tap(target.first);
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}
