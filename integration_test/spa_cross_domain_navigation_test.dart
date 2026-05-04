// SPA cross-domain navigation interception (NAV-style integration check).
//
// Drives the production navigation pipeline against a live WebView and
// a real local HttpServer page, then asserts via LogService that an
// SPA's attempt to open a different "site" inside its own webview
// (`window.location.href = '<cross-domain>'`, no user gesture) is
// intercepted by NavigationDecisionEngine and silently CANCELed under
// the default `blockAutoRedirects=true` posture. Complements the
// engine-level harness in `test/nested_webview_navigation_test.dart`
// by exercising the full WebView <-> Dart callback wiring at
// lib/web_view_model.dart:619-655 against a real WPE WebKit
// navigation policy delegate, not a Dart-side stub.
//
// Production logs (lib/web_view_model.dart):
//   shouldOverrideUrlLoading: site=... initUrl=... request=<cross> hasGesture=false
//     -> CANCEL (auto-redirect blocked, no user gesture)
//
// The cross-domain URL must NEVER be committed as the parent webview's
// currentUrl — proven by the absence of an `onUrlChanged` allow-path
// log line that names it.
//
// Site activation triggers a real WebView mount + HTTP load + JS
// execution; the wayland + WEBKIT_DISABLE_SANDBOX chroot harness is
// required (see openspec/specs/integration-tests/spec.md).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

// Hostname is .invalid (RFC 6761) so DNS resolution fails fast even if
// the WebView were to attempt the request — the assertion is on the
// policy-callback CANCEL log fired *before* the network request.
const _crossDomainUrl = 'http://other.example.invalid/landing';

late HttpServer _server;
late String _siteUrl;

String _spaHtml() => '''
<!DOCTYPE html>
<html>
<head><title>SPA Test</title></head>
<body>
<h1 id="hello">SPA loaded</h1>
<script>
// Simulate an SPA that, after rendering, tries to "open another site
// in itself" via JS-driven navigation. No user gesture — the
// production posture (blockAutoRedirects=true) must intercept this.
setTimeout(function() {
  window.location.href = '$_crossDomainUrl';
}, 500);
</script>
</body>
</html>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    isDemoMode = true;

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write(_spaHtml());
      req.response.close();
    });
    _siteUrl = 'http://127.0.0.1:${_server.port}/';

    final site = WebViewModel(
      siteId: 'spa-1',
      initUrl: _siteUrl,
      name: 'SPA Site',
      // Strip every downloaded-blob-dependent guard so the test does
      // not depend on a populated DNS blocklist / content blocker /
      // LocalCDN. The umbrella `trackingProtectionEnabled` would
      // otherwise force the four subordinates back ON regardless of
      // their stored value (see lib/web_view_model.dart:577-583).
      trackingProtectionEnabled: false,
      clearUrlEnabled: false,
      dnsBlockEnabled: false,
      contentBlockEnabled: false,
      localCdnEnabled: false,
      // Default blockAutoRedirects=true is the posture under test.
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(site.toJson())],
    });
  });

  tearDownAll(() async {
    await _server.close(force: true);
  });

  testWidgets(
      'SPA cross-domain auto-navigation is intercepted and silently blocked',
      (tester) async {
    LogService.instance.clear();

    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Open drawer + activate the SPA site (mounts the real WebView
    // and kicks off the page load).
    final allTile = find.byKey(const ValueKey(kAllWebspaceId));
    expect(allTile, findsOneWidget);
    await tester.tap(allTile);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final tile = find.text('SPA Site');
    expect(tile, findsOneWidget,
        reason: 'seeded SPA site should appear in the drawer');
    await tester.tap(tile);

    // pumpAndSettle deadlocks on a live WebView. Poll the LogService
    // until the expected entry shows up — gives the WebView mount,
    // the page load, the JS timer, and the policy callback all the
    // time they need on the headless CI runner.
    Future<LogEntry?> waitForLog(bool Function(LogEntry) match,
        {Duration timeout = const Duration(seconds: 60)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 250));
        for (final e in LogService.instance.entries) {
          if (match(e)) return e;
        }
      }
      return null;
    }

    void dumpLogs(String reason) {
      // ignore: avoid_print
      print('$reason. Captured ${LogService.instance.entries.length} logs:');
      for (final e in LogService.instance.entries) {
        // ignore: avoid_print
        print('  [${e.tag}/${e.level.name}] ${e.message}');
      }
    }

    // 1. WebView fired shouldOverrideUrlLoading for the cross-domain URL.
    final overrideEntry = await waitForLog((e) =>
        e.tag == 'WebView' &&
        e.message.startsWith('shouldOverrideUrlLoading') &&
        e.message.contains(_crossDomainUrl));
    if (overrideEntry == null) {
      dumpLogs('shouldOverrideUrlLoading for $_crossDomainUrl never fired');
    }
    expect(overrideEntry, isNotNull,
        reason: 'shouldOverrideUrlLoading must fire for the SPA-driven '
            'cross-domain navigation attempt — without it the WebView '
            'is bypassing our navigation policy callback entirely');
    expect(overrideEntry!.message, contains('hasGesture=false'),
        reason: 'JS-initiated location.href has no user gesture');
    expect(overrideEntry.message, contains('initUrl=$_siteUrl'),
        reason: 'log line should attribute the request to the SPA site');

    // 2. Engine logged its CANCEL decision (silent block under
    //    blockAutoRedirects=true + no gesture).
    final cancelLogged = LogService.instance.entries.any((e) =>
        e.tag == 'WebView' &&
        e.message.contains('CANCEL') &&
        e.message.contains('auto-redirect blocked'));
    if (!cancelLogged) {
      dumpLogs('expected "CANCEL (auto-redirect blocked...)" log entry was missing');
    }
    expect(cancelLogged, isTrue,
        reason: 'engine must silently CANCEL the SPA cross-domain '
            'attempt and log the auto-redirect-blocked rationale');

    // 3. The cross-domain URL must NEVER show up as a committed
    //    currentUrl in onUrlChanged. The handler logs three diagnostic
    //    sub-cases ('blocked', 'redirect detected', 'suppressed') for
    //    cross-domain events; an `onUrlChanged` line that names the
    //    cross-domain URL without one of those sub-strings would
    //    indicate the SPA actually swapped the parent webview's URL.
    final committed = LogService.instance.entries.any((e) =>
        e.tag == 'WebView' &&
        e.message.startsWith('onUrlChanged') &&
        e.message.contains(_crossDomainUrl) &&
        !e.message.contains('blocked') &&
        !e.message.contains('redirect detected') &&
        !e.message.contains('suppressed'));
    if (committed) {
      dumpLogs('cross-domain URL was committed as parent currentUrl');
    }
    expect(committed, isFalse,
        reason: 'parent webview must not commit the cross-domain URL '
            'as its currentUrl — it stays on the in-domain SPA');
  });
}
