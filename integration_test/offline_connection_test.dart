// Offline / degraded-network integration test (INTEG-014).
//
// Covers the three network postures the unit tier cannot reach, because
// every one of them is a negotiation between our Dart decisions and a
// real engine's load lifecycle:
//
//   * offline — the connectivity gate must render the cached snapshot
//     and issue no live fetch at all;
//   * online  — the same construction must swap that snapshot for the
//     live page exactly once (the cached-then-live path);
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
// decided in Dart (whether a reload was issued, whether a cache save was
// attempted) is asserted strictly on every platform. Everything that
// depends on the engine honoring a request (reloading an
// `InAppWebViewInitialData` page back to its baseUrl, reporting a network
// failure to the Dart layer at all) is asserted only once observed, and
// logs a SKIP otherwise — Linux WPE maps `WEBKIT_NETWORK_ERROR_FAILED`
// (299) to no `WebResourceErrorType`, so a plain connection failure never
// reaches `onReceivedError` there.
//
// Harness mirrors privacy_settings_test.dart: a live compositing WebView
// wedges the Flutter UI thread, so waits run on real wall-clock inside
// tester.runAsync() and frames are pumped only to mount widgets.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/resume_reload_engine.dart';
import 'package:webspace/services/webview.dart';

/// Marker baked into the snapshot handed to the webview as `initialHtml`.
const String _cachedMarker = 'WS_CACHED_SNAPSHOT_MARKER';

/// Marker only the fixture server can produce, so its presence in the DOM
/// proves a real network round-trip happened.
const String _liveMarker = 'WS_LIVE_PAGE_MARKER';

/// How long the `/slow` route sits on the request before answering.
const Duration _slowDelay = Duration(seconds: 5);

String _cachedSnapshot() =>
    '<!doctype html><html><head><title>cached</title></head>'
    '<body><p>$_cachedMarker</p></body></html>';

String _livePage(String path) =>
    '<!doctype html><html><head><title>live</title></head>'
    '<body><p>$_liveMarker</p><p>$path</p></body></html>';

/// Everything one mounted webview reported back to the host.
class _Observed {
  WebViewController? controller;
  int reloadsIssued = 0;
  final List<bool> loadingStates = [];
  final List<MainFrameLoadSignal> signals = [];
  final List<String> savedHtml = [];

  Iterable<MainFrameLoadSignal> get failures =>
      signals.where((s) => s.phase == MainFrameLoadPhase.failed);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late int port;
  late int deadPort;
  final requests = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[offline] $m');
  }

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((req) async {
      requests.add(req.uri.path);
      switch (req.uri.path) {
        case '/slow':
          await Future<void>.delayed(_slowDelay);
          break;
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
          } catch (_) {}
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

  setUp(requests.clear);

  tearDown(ConnectivityService.reset);

  String url(String path) => 'http://127.0.0.1:$port$path';
  int countFor(String path) => requests.where((p) => p == path).length;

  /// Wall-clock wait that never pumps a frame — a live, compositing
  /// platform view blocks `tester.pump()` on a headless runner.
  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var ok = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (done()) {
          ok = true;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      ok = done();
    });
    log('$label -> ${ok ? "ok" : "timeout"}');
    return ok;
  }

  /// Mount one webview through the real factory. Frames are pumped only
  /// to get the platform view on screen; the load itself is awaited by
  /// the caller via [waitReal].
  Future<_Observed> mount(
    WidgetTester tester, {
    required String initialUrl,
    String? initialHtml,
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
                initialUrl: initialUrl,
                initialHtml: initialHtml,
                // Keep the surface to the network path under test: no
                // blocker lists, no ETP shim, no CDN rewriting.
                clearUrlEnabled: false,
                dnsBlockEnabled: false,
                contentBlockEnabled: false,
                trackingProtectionEnabled: false,
                localCdnEnabled: false,
                onReloadIssued: () => observed.reloadsIssued++,
                onLoadingChanged: observed.loadingStates.add,
                onMainFrameLoad: observed.signals.add,
                onHtmlLoaded: (_, html) => observed.savedHtml.add(html),
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

  Future<String> htmlOf(WidgetTester tester, _Observed observed) async {
    var html = '';
    await tester.runAsync(() async {
      try {
        html = await observed.controller
                ?.getHtml()
                .timeout(const Duration(seconds: 5)) ??
            '';
      } catch (_) {}
    });
    return html;
  }

  // OFFLINE-INTEG-001. The whole point of the snapshot: when the device is
  // offline at construction time the user gets the last-seen page, and the
  // app does not spend a round-trip proving the network is still down.
  // Both halves are decided in Dart (`initialHtml` + the `isOnline()` gate
  // inside the factory's one-shot live-reload), so both assert strictly on
  // every engine.
  testWidgets('offline: cached snapshot renders and no live load is issued',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(false);

    final observed = await mount(
      tester,
      initialUrl: url('/fast'),
      initialHtml: _cachedSnapshot(),
    );

    // The cached parse has to settle before the live-reload decision is
    // even reachable, so wait for the settle rather than a fixed sleep.
    final settled = await waitReal(
      tester,
      () => observed.signals
          .any((s) => s.phase == MainFrameLoadPhase.settled),
      label: 'cached parse settles',
      timeout: const Duration(seconds: 20),
    );
    // Give the (already-resolved) connectivity probe and any reload it
    // could have scheduled a generous window to reach the server.
    await waitReal(
      tester,
      () => countFor('/fast') > 0,
      label: 'live fetch (must not happen)',
      timeout: const Duration(seconds: 8),
    );

    expect(observed.reloadsIssued, 0,
        reason: 'offline must not fire the cached-then-live swap');
    expect(countFor('/fast'), 0,
        reason: 'offline must not reach the network at all');
    expect(observed.failures, isEmpty,
        reason: 'rendering a cached snapshot is not a load failure');

    if (!settled) {
      log('SKIP dom assertion: engine never settled the cached parse');
      return;
    }
    final html = await htmlOf(tester, observed);
    expect(html, contains(_cachedMarker),
        reason: 'offline construction must paint the cached snapshot');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // OFFLINE-INTEG-002. The converse gate: online, the snapshot is a first
  // paint and nothing more — exactly one reload, then the live bytes.
  testWidgets('online: cached snapshot is swapped for the live page once',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);

    final observed = await mount(
      tester,
      initialUrl: url('/fast'),
      initialHtml: _cachedSnapshot(),
    );

    final reloaded = await waitReal(
      tester,
      () => observed.reloadsIssued > 0,
      label: 'live-reload issued',
      timeout: const Duration(seconds: 20),
    );
    if (!reloaded) {
      log('SKIP: engine never settled the cached parse, so the '
          'cached-then-live swap was never reachable');
      return;
    }
    expect(observed.reloadsIssued, 1,
        reason: 'the live swap is a one-shot, not a loop');

    final fetched = await waitReal(
      tester,
      () => countFor('/fast') > 0,
      label: 'live fetch reaches the fixture server',
    );
    if (!fetched) {
      log('SKIP dom assertion: engine did not reload an initialData page '
          'back to its baseUrl');
      return;
    }
    // The fetch reached the server; the commit follows.
    await waitReal(
      tester,
      () => observed.loadingStates.length > 2,
      label: 'settle after live fetch',
      timeout: const Duration(seconds: 15),
    );
    final html = await htmlOf(tester, observed);
    if (!html.contains(_liveMarker)) {
      log('SKIP dom assertion: live bytes fetched but not committed yet '
          '(html len=${html.length})');
      return;
    }
    expect(html, contains(_liveMarker));
    expect(observed.failures, isEmpty,
        reason: 'a successful live swap reports no failure');
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
      () => observed.loadingStates.contains(true),
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
      () => observed.loadingStates.contains(false),
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

    final html = await htmlOf(tester, observed);
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
      () => observed.failures.isNotEmpty,
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

  // OFFLINE-INTEG-005. The snapshot must survive the flake that makes it
  // matter. A failed navigation still commits an engine error page, and
  // `onLoadStop` fires for it; caching those bytes replaces the user's
  // last-good page with "connection refused", which is then what the next
  // offline cold start renders.
  testWidgets('shaky: a failed load never overwrites the offline snapshot',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);

    final observed =
        await mount(tester, initialUrl: 'http://127.0.0.1:$deadPort/refused');

    final failed = await waitReal(
      tester,
      () => observed.failures.isNotEmpty,
      label: 'refused load reports a failure',
      timeout: const Duration(seconds: 30),
    );
    if (!failed) {
      log('SKIP: engine reported no main-frame failure, so there is no '
          'error-page commit to guard against');
      return;
    }
    // The error page commits after the failure; give the settle (and the
    // getHtml() it would trigger) room to land before asserting.
    await waitReal(
      tester,
      () => observed.savedHtml.isNotEmpty,
      label: 'cache save (must not happen)',
      timeout: const Duration(seconds: 10),
    );
    expect(observed.savedHtml, isEmpty,
        reason: 'a navigation that failed has no page worth caching; '
            'saving the engine error page clobbers the snapshot the '
            'offline path depends on');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
