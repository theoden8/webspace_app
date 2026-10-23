// The Android TV tier (INTEG-017; NAV-016, HS-004), run on an Android TV emulator by
// scripts/run_android_tv_tests.sh. A remote's keys go into the activity as
// Android delivers them (RemoteInputPlugin's debug-only `debugPressKey`), so
// each one takes the real path: FlutterView first, then, where Flutter hands
// it back, the System WebView inside it.
//
// It asserts what only a TV can show: that the app knows a remote drives it,
// that the TV's launcher takes no pinned shortcut, that the D-pad moves the
// page once focus reaches it, and that an arrow the page has no use for
// leaves it for the app's own controls, from the page itself and from a
// cross-origin frame filling it.
//
// Everything here needs the TV's own answers, so off the TV tier
// (WS_TV_TIER unset: the phone emulator, the desktop jobs that run every file)
// it skips.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/remote_input.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/remote_controls.dart';
import 'bare_site.dart';
import 'fixture_server.dart';

const _tvTier = bool.fromEnvironment('WS_TV_TIER');

const _channel = MethodChannel('org.codeberg.theoden8.webspace/remote_input');

// android.view.KeyEvent's codes for the remote's D-pad.
const _dpadUp = 19;
const _dpadDown = 20;

/// A page taller than the screen, its links one under another, so a D-pad
/// press either moves focus between links or scrolls. In a frame it tells
/// its parent which link has focus, which the parent could not read across
/// origins.
String _linksPage() => '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body{margin:0;font:24px sans-serif;background:#123524;color:#fff}
  a{display:block;height:120px;line-height:120px;color:#fff}
</style>
<script>
  document.addEventListener('focusin', function(e) {
    if (window !== window.top) window.parent.postMessage({ inner: e.target.id }, '*');
  });
</script></head><body>
${[for (var i = 0; i < 20; i++) '<a id="l$i" href="#l$i">link $i</a>'].join()}
</body></html>''';

/// A page whose whole content is [frame], from another origin: every key
/// the remote sends goes to the frame's document, never to this one.
String _framedPage(String frame) => '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body{margin:0}
  iframe{display:block;border:0;width:100%;height:100vh}
</style>
<script>
  window.addEventListener('message', function(e) {
    if (e.data && e.data.inner) window.__inner = e.data.inner;
  });
</script></head><body><iframe src="$frame"></iframe></body></html>''';

const _probeJs = '''
JSON.stringify({
  ready: document.readyState,
  focused: document.hasFocus(),
  active: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null,
  inner: window.__inner || null,
  y: Math.round(window.scrollY)
})''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late HttpServer frameServer;
  late String page;
  late String framed;

  void serve(HttpServer on, {required String Function() html}) =>
      listenFixture(on, onEvent: (request) {
        request.response
          ..headers.contentType = ContentType.html
          ..write(html());
        unawaited(request.response.close());
      });

  setUpAll(() async {
    if (!_tvTier) return;
    await bareSetUp();
    await RemoteInput.probe();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    frameServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    page = 'http://127.0.0.1:${server.port}/links';
    framed = 'http://127.0.0.1:${frameServer.port}/framed';
    serve(server, html: _linksPage);
    serve(frameServer, html: () => _framedPage(page));
  });

  tearDownAll(() async {
    if (!_tvTier) return;
    await server.close(force: true);
    await frameServer.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('remote_tv_test: $message');
  }

  Future<void> press(WidgetTester tester, {required int keyCode}) async {
    await tester.runAsync(() async {
      await _channel.invokeMethod<void>('debugPressKey', {'keyCode': keyCode});
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
  }

  Future<Map<String, dynamic>?> probe(
    WidgetTester tester, {
    required WebViewController? controller,
  }) async {
    Map<String, dynamic>? out;
    await tester.runAsync(() async {
      try {
        final raw = await controller
            ?.evaluateJavascriptReturning(_probeJs)
            .timeout(const Duration(seconds: 5));
        if (raw == null) return;
        final decoded = jsonDecode(raw is String ? raw : '$raw');
        if (decoded is Map<String, dynamic>) out = decoded;
      } on TimeoutException {
        // The bridge is not up yet; the caller asks again.
      } on FormatException {
        // Not the probe's JSON yet.
      }
    });
    return out;
  }

  testWidgets(
    'a TV knows a remote drives it, and offers no pinned shortcut its '
    'launcher would refuse (INTEG-017, NAV-016, HS-004)',
    (tester) async {
      expect(RemoteInput.driven, isTrue,
          reason: 'an Android TV is in TV mode, without a touchscreen');
      final canPin = await ShortcutService.canAddShortcuts();
      log('launcher takes pinned shortcuts: $canPin');
      expect(canPin, isFalse,
          reason: 'a TV launcher takes no pinned shortcut, so the menu '
              'must not offer one (HS-004)');
    },
    skip: !_tvTier,
  );

  /// Down from the app bar onto [url], four Downs within it, then Ups until
  /// the app bar has focus again. [at] names where in the page focus is, so
  /// the Downs can be seen to move it.
  Future<void> journey(
    WidgetTester tester, {
    required String url,
    required Object? Function(Map<String, dynamic>? state) at,
  }) async {
    final bar = FocusNode(debugLabel: 'app bar');
    addTearDown(bar.dispose);
    WebViewController? controller;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => RemoteControls(child: child!),
      home: Scaffold(
        body: Column(
          children: [
            TextButton(
              focusNode: bar,
              onPressed: () {},
              child: const Text('app bar'),
            ),
            Expanded(
              child: WebViewFactory.createWebView(
                config: WebViewConfig(
                  cacheFirst: false,
                  hooks: bareHooks(),
                  key: ValueKey(url),
                  posture: barePosture(url, siteId: SiteId('remote-tv')),
                  initialUrl: url,
                ),
                onControllerCreated: (c) => controller = c,
              ),
            ),
          ],
        ),
      ),
    ));

    Map<String, dynamic>? state;
    for (var i = 0; i < 90 && state?['ready'] != 'complete'; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)));
      await tester.pump();
      state = await probe(tester, controller: controller);
    }
    log('loaded: $state');
    expect(state?['ready'], 'complete', reason: 'the page never loaded');

    bar.requestFocus();
    await tester.pump();
    await press(tester, keyCode: _dpadDown);
    expect(bar.hasFocus, isFalse,
        reason: 'Down from the app bar moves focus onto the page');
    for (var i = 0; i < 10 && state?['focused'] != true; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      state = await probe(tester, controller: controller);
    }
    log('entered: $state');
    expect(state?['focused'], isTrue,
        reason: 'the webview takes native focus as Flutter focus enters it');

    final before = state;
    for (var i = 0; i < 4; i++) {
      await press(tester, keyCode: _dpadDown);
    }
    state = await probe(tester, controller: controller);
    log('after 4 x Down: $state');
    expect(bar.hasFocus, isFalse, reason: 'the page keeps the D-pad');
    expect(at(state), isNot(at(before)),
        reason: 'Down moved focus between the links or scrolled the page');

    var presses = 0;
    while (!bar.hasPrimaryFocus && presses < 40) {
      await press(tester, keyCode: _dpadUp);
      presses++;
    }
    state = await probe(tester, controller: controller);
    log('after $presses x Up: $state, bar focused: ${bar.hasPrimaryFocus}');
    expect(bar.hasPrimaryFocus, isTrue,
        reason: 'at the top, an Up the page has no use for leaves it for '
            'the app bar above');
  }

  testWidgets(
    'the D-pad moves the page once focus reaches it, and an arrow it has no '
    'use for leaves it for the app bar (INTEG-017, NAV-016)',
    (tester) => journey(
      tester,
      url: page,
      at: (state) => (state?['active'], state?['y']),
    ),
    skip: !_tvTier,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'in a cross-origin frame filling the page, the D-pad moves the frame, '
    'and an arrow the frame has no use for leaves the page too '
    '(INTEG-017, NAV-016)',
    (tester) => journey(
      tester,
      url: framed,
      at: (state) => state?['inner'],
    ),
    skip: !_tvTier,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
