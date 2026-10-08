// Passkeys through the Credential Manager bridge on a real Android System
// WebView, against a real relying party and a real credential provider
// (PASSKEY-012).
//
// Driven by scripts/run_android_passkey_tests.sh, which installs the test
// provider (tool/passkey_gate/test_provider), trusts or distrusts this app
// in it, serves the RP (tool/passkey_gate/rp_server) on the emulator's
// localhost through `adb reverse`, taps through the system passkey sheet,
// and reads the provider's logcat and the RP's /results for the evidence
// the assertions here cannot see. Every other job skips this file: without
// the harness there is nothing to talk to.
//
// Phases, one flutter run each (--dart-define=PASSKEY_GATE_PHASE=...):
//   main     - the page sees WebAuthn, registers, and signs in twice, then a
//              second webview signs in with the first one's passkey.
//   refused  - the provider no longer trusts the app: the page sees
//              NotAllowedError and the app is still running.
//   webview  - the WebView's own FOR_BROWSER WebAuthn instead of the bridge.
//              Best effort: reported, never failed on.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/passkey_engine.dart';
import 'package:webspace/services/passkey_native.dart';
import 'package:webspace/services/webview.dart';
import 'bare_site.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/services/page_js.dart';

const _gate = bool.fromEnvironment('PASSKEY_GATE');
const _phase = String.fromEnvironment('PASSKEY_GATE_PHASE', defaultValue: 'main');
const _rp = String.fromEnvironment('PASSKEY_GATE_RP', defaultValue: 'http://localhost:8443/');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(PageJs.load);

  void report(String what, {required Object? value}) {
    // ignore: avoid_print
    print('PASSKEY_GATE $what ${jsonEncode(value)}');
  }

  if (!_gate || !Platform.isAndroid) {
    testWidgets('passkey gate needs its harness', (tester) async {
      report('skip',
          value:
              'run scripts/run_android_passkey_tests.sh on an Android device');
    });
    return;
  }

  Future<void> settle(WidgetTester tester, {required Duration d}) async {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(d));
  }

  // The script's uiautomator dumps of the passkey sheet turn accessibility
  // on, and the binding then holds a semantics handle until the platform
  // turns it off again; ending a test before that fails its handle check.
  Future<void> semanticsOff(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (tester.binding.platformDispatcher.semanticsEnabled &&
        DateTime.now().isBefore(deadline)) {
      await settle(tester, d: const Duration(milliseconds: 300));
    }
    await tester.pump();
  }

Future<Map<String, dynamic>?> read(WidgetTester tester,
    {required WebViewController c, required String expression}) async {
  Map<String, dynamic>? out;
  await tester.runAsync(() async {
    try {
      final raw = await c
          .evaluateJavascriptReturning('JSON.stringify($expression)')
          .timeout(const Duration(seconds: 5));
      if (raw == null) return;
      final decoded = jsonDecode(raw is String ? raw : '$raw');
      if (decoded is String) {
        final inner = jsonDecode(decoded);
        if (inner is Map<String, dynamic>) out = inner;
      } else if (decoded is Map<String, dynamic>) {
        out = decoded;
      }
    } catch (_) {
      // The page or the bridge is still coming up.
    }
  });
  return out;
}

Future<void> waitForPage(WidgetTester tester,
    {required WebViewController? Function() c, required String label}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await settle(tester, d: const Duration(milliseconds: 400));
    final controller = c();
    if (controller == null) continue;
    final ready = await read(tester,
        c: controller,
        expression:
            '({ready: !!(window.gate && document.getElementById("ready"))})');
    if (ready?['ready'] == true) return;
  }
  fail('$label: the RP page never loaded from $_rp');
}

Future<Map<String, dynamic>> probe(WidgetTester tester,
    {required WebViewController c}) async {
  await tester.runAsync(() => c.evaluateJavascript('window.gate.probe()'));
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    await settle(tester, d: const Duration(milliseconds: 300));
    final p =
        await read(tester, c: c, expression: 'window.gate.probed || null');
    if (p != null) return p;
  }
  fail('the page never answered its probe');
}

  /// Start a ceremony in the page and wait for it to settle. The system
  /// sheet the script taps through sits on top of the app meanwhile.
Future<Map<String, dynamic>> ceremony(WidgetTester tester,
    {required WebViewController c,
    required String kind,
    required String name}) async {
  await tester.runAsync(() => c.evaluateJavascript(
      'window.gate.run(${jsonEncode(kind)}, ${jsonEncode(name)})'));
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(deadline)) {
    await settle(tester, d: const Duration(milliseconds: 500));
    final s =
        await read(tester, c: c, expression: 'window.gate.status || null');
    if (s != null && s['state'] != 'running') return s;
  }
  fail('$kind for $name never finished');
}

WebViewConfig config(String siteId, {required PasskeyBackend backend}) =>
    WebViewConfig(
      hooks: bareHooks(),
      key: ValueKey('passkey-$siteId'),
      posture: barePosture(_rp, siteId: siteId),
      initialUrl: _rp,
      passkeys: PasskeyAccess.forHost(
        enabled: true,
        isOnScreen: () => true,
        android: backend == PasskeyBackend.credentialManager,
        apple: backend == PasskeyBackend.webView,
      ),
    );

  Widget host(List<({WebViewConfig config, void Function(WebViewController) onController})> views) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Column(
            children: [
              for (final v in views)
                Expanded(
                  child: WebViewFactory.createWebView(
                    config: v.config,
                    onControllerCreated: v.onController,
                  ),
                ),
            ],
          ),
        ),
      );

  testWidgets('native status', (tester) async {
    final status = await PasskeyNative.status();
    report('status', value: {
      'phase': _phase,
      'sdk': status.sdk,
      'feature': status.feature,
      'permission': status.permission,
      'available': status.available,
      'webViewSupport': status.webViewSupport,
    });
    if (_phase != 'webview') {
      expect(status.available, isTrue,
          reason: 'Credential Manager must be usable here: sdk=${status.sdk} '
              'feature=${status.feature} permission=${status.permission}');
    }
  });

  if (_phase == 'main') {
    testWidgets('register, then sign in twice (G0, G2, G3)', (tester) async {
      WebViewController? c;
      await tester.pumpWidget(host([
        (
          config:
              config('passkey-a', backend: PasskeyBackend.credentialManager),
          onController: (x) => c = x
        ),
      ]));
      await waitForPage(tester, c: () => c, label: 'tab 1');

      final p = await probe(tester, c: c!);
      report('probe', value: p);
      expect(p['secure'], isTrue, reason: 'http://localhost must be a secure context');
      expect(p['pkc'], 'function', reason: 'the shim installs PublicKeyCredential');
      expect(p['uvpaa'], isTrue, reason: 'the bridge reports a platform authenticator');

      final reg =
          await ceremony(tester, c: c!, kind: 'register', name: 'alice');
      report('register', value: reg);
      expect(reg['state'], 'done', reason: '$reg');
      expect(reg['verified'], isTrue, reason: '$reg');
      expect(reg['origin'], 'http://localhost:8443');
      expect(reg['type'], 'webauthn.create');

      final first = await ceremony(tester, c: c!, kind: 'login', name: 'alice');
      report('login1', value: first);
      expect(first['verified'], isTrue, reason: '$first');
      final second =
          await ceremony(tester, c: c!, kind: 'login', name: 'alice');
      report('login2', value: second);
      expect(second['verified'], isTrue, reason: '$second');
      expect((second['counter'] as num) > (first['counter'] as num), isTrue,
          reason: 'the signature counter must increase: $first then $second');
      await semanticsOff(tester);
    }, timeout: const Timeout(Duration(minutes: 8)));

    testWidgets('a second webview signs in with the first one\'s passkey (G8)',
        (tester) async {
      WebViewController? a;
      WebViewController? b;
      await tester.pumpWidget(host([
        (
          config:
              config('passkey-tab1', backend: PasskeyBackend.credentialManager),
          onController: (x) => a = x
        ),
        (
          config:
              config('passkey-tab2', backend: PasskeyBackend.credentialManager),
          onController: (x) => b = x
        ),
      ]));
      await waitForPage(tester, c: () => a, label: 'tab 1');
      await waitForPage(tester, c: () => b, label: 'tab 2');

      final reg = await ceremony(tester, c: a!, kind: 'register', name: 'bob');
      report('tab1-register', value: reg);
      expect(reg['verified'], isTrue, reason: '$reg');
      final login = await ceremony(tester, c: b!, kind: 'login', name: 'bob');
      report('tab2-login', value: login);
      expect(login['verified'], isTrue, reason: '$login');
      final untouched =
          await read(tester, c: a!, expression: 'window.gate.status');
      expect(untouched?['kind'], 'register',
          reason: 'tab 2\'s ceremony must not answer tab 1\'s page: $untouched');
      await semanticsOff(tester);
    }, timeout: const Timeout(Duration(minutes: 8)));
  }

  if (_phase == 'refused') {
    testWidgets('an untrusted app is refused with NotAllowedError (G4)', (tester) async {
      WebViewController? c;
      await tester.pumpWidget(host([
        (
          config: config('passkey-refused',
              backend: PasskeyBackend.credentialManager),
          onController: (x) => c = x
        ),
      ]));
      await waitForPage(tester, c: () => c, label: 'refused');
      final reg =
          await ceremony(tester, c: c!, kind: 'register', name: 'carol');
      report('refused-register', value: reg);
      expect(reg['state'], 'error', reason: '$reg');
      expect(reg['name'], 'NotAllowedError', reason: '$reg');
      expect(reg['isDomException'], isTrue);
      final alive = await probe(tester, c: c!);
      expect(alive['secure'], isTrue, reason: 'the page must survive the refusal');
      await semanticsOff(tester);
    }, timeout: const Timeout(Duration(minutes: 6)));
  }

  if (_phase == 'webview') {
    testWidgets('the WebView\'s own FOR_BROWSER WebAuthn (best effort)', (tester) async {
      final status = await PasskeyNative.status();
      if (!status.webViewSupport) {
        report('webview', value: {
          'outcome': 'unsupported',
          'reason': 'WEB_AUTHENTICATION not advertised'
        });
        return;
      }
      WebViewController? c;
      await tester.pumpWidget(host([
        (
          config: config('passkey-webview', backend: PasskeyBackend.webView),
          onController: (x) => c = x
        ),
      ]));
      await waitForPage(tester, c: () => c, label: 'webview');
      await tester.runAsync(() => c!.reload());
      await waitForPage(tester, c: () => c, label: 'webview after reload');
      final p = await probe(tester, c: c!);
      final reg = await ceremony(tester, c: c!, kind: 'register', name: 'dave');
      report('webview', value: {'probe': p, 'register': reg});
      await semanticsOff(tester);
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
