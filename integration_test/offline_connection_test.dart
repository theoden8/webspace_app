// Offline / degraded-network integration test (INTEG-014).
//
// Covers the three network postures the unit tier cannot reach, because
// every one of them is a negotiation between our Dart decisions and a
// real engine's load lifecycle:
//
//   * offline — a cache-first build must render the engine's stored copy
//     and issue no live fetch at all;
//   * online  — the same build must swap that copy for the live page
//     exactly once (the cache-first-then-live path);
//   * slow    — a response that takes seconds must complete, and must
//     never be reported as a load failure;
//   * shaky   — a refused connection and a truncated response must both
//     surface as a main-frame failure whose error type is in
//     `ResumeReloadEngine.retryableErrorTypes`, or PAUSE-022 recovery
//     never fires for the exact case it exists for.
//
// Every scenario runs against a loopback fixture server, so "offline" is
// simulated at the layer the app actually decides on
// (`ConnectivityService.onlineOverride`) rather than by cutting the
// runner's network, and "shaky" is produced by the server dropping the
// socket rather than by waiting for a real flake.
//
// Assertion posture, following privacy_settings_test.dart: everything
// decided in Dart (whether a reload was issued) is asserted strictly on
// every platform. A cache-first load is asserted strictly wherever
// `engineLoadsCacheFirst` holds, since the app claims it there; WPE has no
// per-load cache policy, so those scenarios SKIP on Linux. Reporting a
// network failure to the Dart layer at all is asserted only once observed,
// and logs a SKIP otherwise — Linux WPE maps `WEBKIT_NETWORK_ERROR_FAILED`
// (299) to no `WebResourceErrorType`, so a plain connection failure never
// reaches `onReceivedError` there.
//
// Harness mirrors privacy_settings_test.dart: a live compositing WebView
// wedges the Flutter UI thread, so waits run on real wall-clock inside
// tester.runAsync() and frames are pumped only to mount widgets.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/html_source.dart' show engineLoadsCacheFirst;
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/webview.dart';
import 'bare_site.dart';
import 'fixture_server.dart';
import 'helpers/ui.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';

/// Marker only the fixture server can produce, so its presence in the DOM
/// proves a real network round-trip happened.
const String _liveMarker = 'WS_LIVE_PAGE_MARKER';

/// The `/cached` route's page, stamped with which request served it. Sent as
/// `no-cache`: the engine stores it, but any normal load or reload must
/// revalidate, so only a cache-first load shows a stamp without a request.
String _stampedPage(int request) =>
    '<!doctype html><html><head><title>stamped</title></head>'
    '<body><p>WS_STAMP_$request</p></body></html>';

/// How long the `/slow` route sits on the request before answering.
const Duration _slowDelay = Duration(seconds: 5);

String _livePage(String path) =>
    '<!doctype html><html><head><title>live</title></head>'
    '<body><p>$_liveMarker</p><p>$path</p></body></html>';

/// Everything one mounted webview reported back to the host.
class _Observed {
  WebViewController? controller;
  int reloadsIssued = 0;

  /// How many requests the fixture had seen when the live reload was issued.
  int? requestsAtReload;
  final List<bool> loadingStates = [];
  final List<MainFrameLoadSignal> signals = [];

  Iterable<MainFrameLoadSignal> get failures =>
      signals.where((s) => s.phase == MainFrameLoadPhase.failed);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(bareSetUp);

  late HttpServer server;
  late int port;
  late int deadPort;
  final requests = <String>[];
  // Not cleared by primeCache, so the live page's stamp differs from the
  // primed copy's.
  var cachedServed = 0;

  void log(String m) {
    // ignore: avoid_print
    print('[offline] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    listenFixture(server, onEvent: (req) async {
      requests.add(req.uri.path);
      switch (req.uri.path) {
        case '/slow':
          await Future<void>.delayed(_slowDelay);
          break;
        case '/cached':
          final res = req.response
            ..headers.contentType = ContentType.html
            ..headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          res.write(_stampedPage(++cachedServed));
          await res.close();
          return;
        case '/truncated':
          // Shaky connection: promise a body, deliver a fragment, drop the
          // socket. Engines surface this as a content-length mismatch /
          // connection-lost failure rather than a clean 4xx.
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.write('HTTP/1.1 200 OK\r\n'
              'Content-Type: text/html\r\n'
              'Content-Length: 8192\r\n'
              'Connection: close\r\n\r\n'
              '<!doctype html><html><body><p>partial');
          try {
            await socket.flush();
          } on SocketException {
            // The client hung up first; the socket goes either way.
          }
          socket.destroy();
          return;
      }
      final res = req.response..headers.contentType = ContentType.html;
      res.write(_livePage(req.uri.path));
      await res.close();
    });

    // A port nothing listens on: bound to claim it, then released, so a
    // connection there is refused rather than filtered (a filtered port
    // would time out and turn every shaky-connection case into a 30s
    // wait).
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    deadPort = probe.port;
    await probe.close();

    log('fixture server on $port, dead port $deadPort');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    requests.clear();
    cachedServed = 0;
  });

  tearDown(ConnectivityService.reset);

  String url(String path) => 'http://127.0.0.1:$port$path';
  int countFor(String path) => requests.where((p) => p == path).length;

  final waitReal = RealWait(log: log);

  /// Mount one webview through the real factory. Frames are pumped only
  /// to get the platform view on screen; the load itself is awaited by
  /// the caller via [waitReal].
  Future<_Observed> mount(
    WidgetTester tester, {
    required String initialUrl,
    bool cacheFirst = false,
  }) async {
    final observed = _Observed();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: WebViewFactory.createWebView(
              config: WebViewConfig(
                hooks: bareHooks(),
                // A second mount in one test would otherwise reuse the
                // first platform view and never load its own initial data.
                key: UniqueKey(),
                // Keep the surface to the network path under test: no
                // blocker lists, no ETP shim.
                posture: barePosture(initialUrl, siteId: SiteId('offline-connection')),
                initialUrl: initialUrl,
                cacheFirst: cacheFirst,
                onReloadIssued: () {
                  observed.reloadsIssued++;
                  observed.requestsAtReload ??= requests.length;
                },
                onLoadingChanged: ({required loading}) => observed.loadingStates.add(loading),
                onMainFrameLoad: observed.signals.add,
              ),
              onControllerCreated: (c) => observed.controller = c,
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return observed;
  }

Future<String> htmlOf(WidgetTester tester,
    {required _Observed observed}) async {
  var html = '';
  await tester.runAsync(() async {
    try {
      html = await observed.controller
              ?.getHtml()
              .timeout(const Duration(seconds: 5)) ??
          '';
    } on TimeoutException {
      // A page that never answers reads as empty.
    }
  });
  return html;
}

  /// A live load of `/cached` that leaves its first stamp in the engine's
  /// cache, then clears the request log for the build under test.
  Future<void> primeCache(WidgetTester tester) async {
    final primed = await mount(tester, initialUrl: url('/cached'));
    final settled = await waitReal(
      tester,
      done: () => primed.signals
          .any((s) => s.phase == MainFrameLoadPhase.settled),
      label: 'priming load settles',
      timeout: const Duration(seconds: 20),
    );
    expect(settled, isTrue, reason: 'the priming load must settle');
    expect(await htmlOf(tester, observed: primed), contains('WS_STAMP_1'));
    requests.clear();
  }

  Future<bool> settledOnce(WidgetTester tester, {required _Observed observed}) =>
      waitReal(
        tester,
        done: () => observed.signals
            .any((s) => s.phase == MainFrameLoadPhase.settled),
        label: 'cache-first load settles',
        timeout: const Duration(seconds: 20),
      );

  // OFFLINE-INTEG-001. Offline at construction, the user gets the page the
  // engine kept, and the app does not spend a round-trip proving the network
  // is still down.
  testWidgets('offline: a cache-first build renders the stored page, no fetch',
      (tester) async {
    if (!engineLoadsCacheFirst) {
      log('SKIP: WPE has no per-load cache policy');
      return;
    }
    ConnectivityService.onlineOverride = Future.value(false);
    await primeCache(tester);

    final observed =
        await mount(tester, initialUrl: url('/cached'), cacheFirst: true);
    expect(await settledOnce(tester, observed: observed), isTrue);
    await waitReal(
      tester,
      done: () => countFor('/cached') > 0,
      label: 'live fetch (must not happen)',
      timeout: const Duration(seconds: 8),
    );

    expect(observed.reloadsIssued, 0,
        reason: 'offline must not fire the live swap');
    expect(countFor('/cached'), 0,
        reason: 'a cache-first load must not reach the network');
    expect(observed.failures, isEmpty);
    expect(await htmlOf(tester, observed: observed), contains('WS_STAMP_1'),
        reason: 'the stored copy is what renders');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // OFFLINE-INTEG-002. Online, the stored copy is a first paint and nothing
  // more: exactly one reload, then the live bytes.
  testWidgets('online: the stored page is swapped for the live page once',
      (tester) async {
    if (!engineLoadsCacheFirst) {
      log('SKIP: WPE has no per-load cache policy');
      return;
    }
    ConnectivityService.onlineOverride = Future.value(true);
    await primeCache(tester);

    final observed =
        await mount(tester, initialUrl: url('/cached'), cacheFirst: true);
    final reloaded = await waitReal(
      tester,
      done: () => observed.reloadsIssued > 0,
      label: 'live reload issued',
      timeout: const Duration(seconds: 20),
    );
    expect(reloaded, isTrue, reason: 'online, the stored copy goes live');
    expect(observed.requestsAtReload, 0,
        reason: 'the first paint came from the cache');
    await waitReal(
      tester,
      done: () => countFor('/cached') > 0 && observed.loadingStates.length > 2,
      label: 'live reload settles',
      timeout: const Duration(seconds: 15),
    );
    await waitReal(
      tester,
      done: () => observed.reloadsIssued > 1,
      label: 'second live reload (must not happen)',
      timeout: const Duration(seconds: 6),
    );
    expect(observed.reloadsIssued, 1,
        reason: 'the live swap is a one-shot, not a loop');
    expect(countFor('/cached'), 1,
        reason: 'the reload revalidates once and nothing more');
    expect(await htmlOf(tester, observed: observed), contains('WS_STAMP_2'),
        reason: 'the live page replaces the stored one');
    expect(observed.failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // OFFLINE-INTEG-006. Offline when the stored page settles is not offline
  // for good: a webview rebuilt on return from the background settles before
  // a per-app firewall lets the app back out (PAUSE-033).
  testWidgets('network back after the stored page settles: still swapped once',
      (tester) async {
    if (!engineLoadsCacheFirst) {
      log('SKIP: WPE has no per-load cache policy');
      return;
    }
    ConnectivityService.onlineOverride = Future.value(false);
    await primeCache(tester);

    final observed =
        await mount(tester, initialUrl: url('/cached'), cacheFirst: true);
    expect(await settledOnce(tester, observed: observed), isTrue);
    expect(observed.reloadsIssued, 0,
        reason: 'no swap while the probe reports offline');
    ConnectivityService.onlineOverride = Future.value(true);

    final reloaded = await waitReal(
      tester,
      done: () => observed.reloadsIssued > 0,
      label: 'live reload issued once online',
      timeout: const Duration(seconds: 30),
    );
    expect(reloaded, isTrue);
    await waitReal(
      tester,
      done: () => observed.reloadsIssued > 1,
      label: 'second live reload (must not happen)',
      timeout: const Duration(seconds: 6),
    );
    expect(observed.reloadsIssued, 1,
        reason: 'the live swap is a one-shot, not a loop');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // OFFLINE-INTEG-003. A slow link is not a broken link. The failure mode
  // this guards is the app treating a multi-second response as an error
  // (and, via PAUSE-022, re-issuing a load that was about to succeed).
  testWidgets('slow response: the load completes and is never a failure',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);

    final observed = await mount(tester, initialUrl: url('/slow'));

    final started = await waitReal(
      tester,
      done: () => observed.loadingStates.contains(true),
      label: 'load starts',
      timeout: const Duration(seconds: 20),
    );
    if (!started) {
      log('SKIP: engine never reported a load start');
      return;
    }
    // Mid-flight, well inside the server's delay: nothing has failed yet.
    expect(observed.failures, isEmpty,
        reason: 'a response still in flight is not a failure');

    final done = await waitReal(
      tester,
      done: () => observed.loadingStates.contains(false),
      label: 'slow load settles',
      timeout: _slowDelay + const Duration(seconds: 30),
    );
    expect(countFor('/slow'), greaterThan(0),
        reason: 'the slow route must have been requested');
    if (!done) {
      log('SKIP dom assertion: engine never settled the slow load');
      return;
    }
    expect(observed.failures, isEmpty,
        reason: 'a slow but successful response must not report a failure');

    final html = await htmlOf(tester, observed: observed);
    expect(html, contains(_liveMarker),
        reason: 'the slow response must still commit');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // OFFLINE-INTEG-004. PAUSE-022's input contract. `ResumeReloadEngine`
  // only re-issues loads whose error type it recognizes as retryable; if a
  // real engine reports a dropped connection as something outside that
  // set, recovery silently never fires. The unit tier cannot catch that —
  // it feeds the engine the strings this test discovers.
  Future<void> assertRetryable(
    WidgetTester tester, {
    required String initialUrl,
    required String label,
  }) async {
    ConnectivityService.onlineOverride = Future.value(true);

    final observed = await mount(tester, initialUrl: initialUrl);

    final failed = await waitReal(
      tester,
      done: () => observed.failures.isNotEmpty,
      label: '$label reports a main-frame failure',
      timeout: const Duration(seconds: 30),
    );
    if (!failed) {
      // Linux WPE: WEBKIT_NETWORK_ERROR_FAILED has no WebResourceErrorType
      // mapping, so the plugin never delivers onReceivedError. Nothing to
      // assert about a signal the engine does not emit.
      log('SKIP $label: engine reported no main-frame failure '
          '(signals=${observed.signals.map((s) => s.phase).toList()})');
      return;
    }
    final types = observed.failures.map((s) => s.errorType!).toSet();
    log('$label error types: $types');
    for (final type in types) {
      expect(ResumeReloadEngine.isRetryable(type), isTrue,
          reason: '$label surfaced as "$type", which ResumeReloadEngine '
              'does not retry — PAUSE-022 recovery would never fire for '
              'a dropped connection on this engine');
    }
  }

  testWidgets('shaky: a refused connection is a retryable failure',
      (tester) async {
    await assertRetryable(
      tester,
      initialUrl: 'http://127.0.0.1:$deadPort/refused',
      label: 'connection refused',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('shaky: a truncated response is a retryable failure',
      (tester) async {
    await assertRetryable(
      tester,
      initialUrl: url('/truncated'),
      label: 'truncated response',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
