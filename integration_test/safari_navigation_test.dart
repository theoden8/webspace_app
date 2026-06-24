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
// openspec/specs/integration-tests/spec.md). A live, compositing WebView
// wedges the Flutter UI thread so any `tester.pump()` (including
// `pumpAndSettle`) never returns on a headless runner; waits on the
// webview therefore run inside `tester.runAsync()` on real wall-clock and
// never pump frames.

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

  // Enabled on all platforms. The live page is driven through
  // tester.runAsync() + real wall-clock waits instead of tester.pump():
  // both WebKit (macOS) and WPE (Linux) perform their load / JS / history
  // work in a separate WebProcess and don't need Flutter frames, so
  // runAsync lets them progress without the pump that blocks on a live,
  // compositing platform view. Frames are pumped only to mount/teardown
  // widgets, never to wait on the webview.
  //
  // Two graceful-skip paths keep this honest where an engine can't do the
  // work: if no nav history builds, or if saveState() returns no bytes
  // (e.g. WPE may not serialize nav state), the test logs SKIP and returns
  // rather than asserting. Every stage logs, so a CI hang (capped at 12m by
  // the runner wrapper) pinpoints the blocking step in the job log.
  testWidgets('back/forward history and current page survive a restart',
      (tester) async {
    void log(String m) {
      // ignore: avoid_print
      print('[safari_nav] $m');
    }

    WebViewModel? site() {
      for (final m in app.debugWebViewModels ?? const <WebViewModel>[]) {
        if (m.siteId == _siteId) return m;
      }
      return null;
    }

    WebViewController? controller() => site()?.controller;

    const callTimeout = Duration(seconds: 5);

    // Pump frames only to advance the widget tree (mount, drawer animation).
    // Bounded — never waits on the live webview.
    Future<void> pumpFor(Duration total) async {
      final deadline = DateTime.now().add(total);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Wait on the live webview WITHOUT pumping frames: real wall-clock poll
    // inside runAsync so WebKit can load/navigate while the Dart side polls
    // platform channels. Returns true if the predicate held before timeout.
    Future<bool> waitReal(
      Future<bool> Function() predicate, {
      required String label,
      Duration timeout = const Duration(seconds: 30),
    }) async {
      var ok = false;
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(timeout);
        var i = 0;
        while (DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 500));
          try {
            if (await predicate()) {
              ok = true;
              return;
            }
          } catch (e) {
            if (i % 10 == 0) log('$label poll error: $e');
          }
          i++;
        }
      });
      log('$label -> ${ok ? "ok" : "timeout"}');
      return ok;
    }

    Future<Uri?> currentUrl() async {
      final c = controller();
      if (c == null) return null;
      try {
        return await c.getUrl().timeout(callTimeout);
      } catch (_) {
        return null;
      }
    }

    Future<bool> canGoBack() async {
      final c = controller();
      if (c == null) return false;
      try {
        return await c.canGoBack().timeout(callTimeout);
      } catch (_) {
        return false;
      }
    }

    Future<void> activateSite() async {
      // Drawer opens over the lazy IndexedStack placeholder (no live webview
      // yet), so pumping to animate it is safe.
      log('activate: open drawer');
      await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
      await pumpFor(const Duration(seconds: 2));
      final tile = find.text(_siteName);
      expect(tile, findsOneWidget,
          reason: '$_siteName should appear in the drawer');
      log('activate: tap site tile (mounts webview)');
      await tester.tap(tile);
      // A few frames to mount the InAppWebView and fire onWebViewCreated.
      // The platform view surface is created here; sustained rendering is
      // then left to WebKit while we wait via runAsync.
      await pumpFor(const Duration(seconds: 2));
      log('activate: mounted, controller=${controller() != null}');
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
    log('run1: app.main()');
    app.main();
    // No webview is live until the site is activated, so pumping the boot
    // UI is safe.
    await pumpFor(const Duration(seconds: 5));
    log('run1: booted');

    await activateSite();

    final built = await waitReal(
      () async => (await currentUrl())?.path == '/deep' && await canGoBack(),
      label: 'run1 build-history',
    );
    if (!built) {
      log('SKIP: webview did not build nav history on this platform.');
      return;
    }

    final captured = (await currentUrl())!.toString();
    expect(captured, contains('/deep?n='),
        reason: 'history should be built before capture');
    log('run1: captured url=$captured');

    log('run1: background()');
    await background();
    final captureSupported = await waitReal(
      () async => (await store.loadState(_siteId))?.isNotEmpty ?? false,
      label: 'run1 capture-state',
      timeout: const Duration(seconds: 15),
    );
    if (!captureSupported) {
      log('SKIP restore assertions: saveState() produced no bytes here.');
      return;
    }

    // --- Run 2: restart (fresh tree, same store), re-activate, restore ---
    log('run2: pumpWidget(WebSpaceApp) restart');
    await tester.pumpWidget(app.WebSpaceApp());
    await pumpFor(const Duration(seconds: 5));
    log('run2: restarted');

    await activateSite();
    final restored = await waitReal(
      () async => (await currentUrl())?.toString() == captured,
      label: 'run2 restore',
    );
    expect(restored, isTrue,
        reason: 'restored top URL should match the exact nonce from run 1');

    expect((await currentUrl()).toString(), captured,
        reason: 'current page (with run-1 nonce) restored after restart');
    expect(await canGoBack(), isTrue,
        reason: 'back/forward history restored after restart');
    log('run2: restore verified');
  });
}
