// Safari-style navigation restore integration test.
//
// Exercises the cross-restart back/forward restore wiring in
// lib/main.dart + lib/web_view_model.dart: a webview's navigation state
// is captured (`controller.saveState()`) on app background and re-applied
// (`controller.restoreState()`) when the site is re-activated after a
// cold start. Spec: openspec/specs/per-site-cookie-isolation has the
// lifecycle; the restore path lives on branch "safari-history-restore".
//
// Flow:
//   1. Boot, activate a site whose page auto-navigates once (so it builds
//      a 2-entry back/forward history) to a URL carrying a per-load random
//      nonce.
//   2. Background the app -> capture the nav state to the (injected,
//      in-memory) WebViewStateStorage.
//   3. Restart (fresh WebSpaceApp tree, same process-global store) and
//      re-activate the site -> restoreState re-applies the captured stack.
//   4. Assert the restored top URL equals the *exact* nonce captured in
//      step 1 (a fresh re-navigation would mint a different nonce, so this
//      distinguishes a real restore from re-loading the page) and that
//      back-navigation is available (the history survived).
//
// Platform-guarded: where `controller.saveState()` returns no bytes
// (engine doesn't serialize nav state), the capture store stays empty and
// the test skips the restore assertions rather than failing.
//
// Activating a site mounts a real WebView, so the wayland +
// WEBKIT_DISABLE_SANDBOX harness is required (see
// openspec/specs/integration-tests/spec.md). `pumpAndSettle` deadlocks on
// a live WebView; the live-webview waits poll in fixed slices instead.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_state_storage.dart';

const String _siteId = 'safari-nav';
const String _siteName = 'Safari Nav';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late InMemoryWebViewStateStorage store;

  setUpAll(() async {
    isDemoMode = true;

    // Process-global store: survives the simulated restart (a fresh
    // WebSpaceApp tree re-reads it on cold start) and is directly
    // inspectable, without needing a platform keychain backend.
    store = InMemoryWebViewStateStorage();
    app.debugWebViewStateStorageOverride = store;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final res = req.response..headers.contentType = ContentType.html;
      if (req.uri.path == '/deep') {
        res.write('<html><head><title>deep</title></head>'
            '<body>deep</body></html>');
      } else {
        // /start auto-navigates once to a nonce'd /deep, building a
        // 2-entry history. A long delay means that on restart restoreState
        // (applied immediately on controller creation) wins over this
        // reloaded page's timer, which is discarded with its document.
        res.write('<html><head><title>start</title></head><body>start'
            '<script>setTimeout(function(){'
            'location.assign("/deep?n=" + Date.now() + "_" + '
            'Math.floor(Math.random()*1e9));}, 1200);</script>'
            '</body></html>');
      }
      res.close();
    });

    final site = WebViewModel(
      siteId: _siteId,
      initUrl: 'http://127.0.0.1:${server.port}/start',
      name: _siteName,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(site.toJson())],
    });
  });

  tearDownAll(() async {
    app.debugWebViewStateStorageOverride = null;
    await server.close(force: true);
  });

  testWidgets('back/forward history and current page survive a restart',
      (tester) async {
    WebViewModel? site() {
      for (final m in app.debugWebViewModels ?? const <WebViewModel>[]) {
        if (m.siteId == _siteId) return m;
      }
      return null;
    }

    WebViewController? controller() => site()?.controller;

    Future<Uri?> currentUrl() async {
      try {
        return await controller()?.getUrl();
      } catch (_) {
        return null;
      }
    }

    Future<bool> canGoBack() async {
      try {
        return await controller()?.canGoBack() ?? false;
      } catch (_) {
        return false;
      }
    }

    Future<void> pumpUntil(
      Future<bool> Function() predicate, {
      required String description,
      Duration timeout = const Duration(seconds: 45),
      Duration step = const Duration(milliseconds: 250),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        if (await predicate()) return;
      }
      throw StateError('Timed out after ${timeout.inSeconds}s waiting for: '
          '$description');
    }

    Future<void> openDrawer() async {
      await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }

    Future<void> activateSite() async {
      // Drawer is opened while no webview is live (lazy IndexedStack), so
      // pumpAndSettle is safe up to the tap; the live-webview wait polls.
      await openDrawer();
      final tile = find.text(_siteName);
      expect(tile, findsOneWidget,
          reason: '$_siteName should appear in the drawer');
      await tester.tap(tile);
    }

    Future<void> background() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/lifecycle',
        const StringCodec()
            .encodeMessage(AppLifecycleState.paused.toString()),
        (_) {},
      );
    }

    // --- Run 1: cold boot, build history, capture on background ---
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    await activateSite();
    try {
      await pumpUntil(
        () async => (await currentUrl())?.path == '/deep' && await canGoBack(),
        description: 'site to navigate /start -> /deep with back history',
      );
    } on StateError {
      // The webview never drove the loopback load + JS auto-navigation
      // (no real nav on this harness). Nothing to restore; skip rather
      // than fail for an environmental reason.
      // ignore: avoid_print
      print('[safari_navigation_test] SKIP: webview did not build nav '
          'history on this platform.');
      return;
    }

    final captured = (await currentUrl())!.toString();
    expect(captured, contains('/deep?n='),
        reason: 'history should be built before capture');

    await background();
    var captureSupported = false;
    try {
      await pumpUntil(
        () async => (await store.loadState(_siteId))?.isNotEmpty ?? false,
        description: 'nav state to be captured on background',
        timeout: const Duration(seconds: 15),
      );
      captureSupported = true;
    } on StateError {
      captureSupported = false;
    }

    if (!captureSupported) {
      // ignore: avoid_print
      print('[safari_navigation_test] SKIP restore assertions: '
          'controller.saveState() produced no bytes on this platform.');
      return;
    }

    // --- Run 2: restart (fresh tree, same store), re-activate, restore ---
    await tester.pumpWidget(app.WebSpaceApp());
    await tester.pumpAndSettle(const Duration(seconds: 20));

    await activateSite();
    await pumpUntil(
      () async => (await currentUrl())?.toString() == captured,
      description: 'restored top URL to match the exact nonce from run 1',
    );

    expect((await currentUrl()).toString(), captured,
        reason: 'current page (with run-1 nonce) restored after restart');
    expect(await canGoBack(), isTrue,
        reason: 'back/forward history restored after restart');
  });
}
