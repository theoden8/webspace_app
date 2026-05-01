// Per-site auto-fullscreen integration test (FS-003).
//
// Activating a site whose `fullscreenMode = true` SHALL hide the
// AppBar — the visible signal of `_isFullscreen` (see lib/main.dart
// `_enterFullscreen` / `_exitFullscreen`). The inverse (switching to
// a non-fullscreen site brings the AppBar back) was tried as a
// second-half assertion but reliably reopening the drawer with a
// live WebView running is its own integration challenge — keep this
// test scoped to the forward direction only.
//
// Site activation triggers a real WebView mount; the wayland +
// WEBKIT_DISABLE_SANDBOX chroot harness is required (see
// openspec/specs/integration-tests/spec.md).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    isDemoMode = true;

    // RFC 5737 reserved test addresses — won't connect, the
    // assertion is on the AppBar visibility transition, not on a
    // page load.
    final immersive = WebViewModel(
      siteId: 'immersive-1',
      initUrl: 'http://192.0.2.1/',
      name: 'Immersive App',
      fullscreenMode: true,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(immersive.toJson())],
    });
  });

  testWidgets(
      'activating a fullscreenMode site hides the AppBar (FS-003)',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    void dumpTexts(String label) {
      // ignore: avoid_print
      print('$label texts: '
          '${find.byType(Text).evaluate().map((e) {
        final w = e.widget;
        return w is Text ? (w.data ?? '?') : '?';
      }).take(40).toList()}');
    }

    // App boots on the All-webspace tile (default selected); the
    // AppBar is visible because no site is yet active OR the active
    // site has fullscreenMode=false.
    expect(find.byType(AppBar), findsWidgets,
        reason: 'AppBar should be visible at app start');

    Future<void> openDrawer() async {
      await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
      await tester.pumpAndSettle(const Duration(seconds: 5));
    }

    Future<void> tapSite(String siteName) async {
      final tile = find.text(siteName);
      if (tile.evaluate().isEmpty) {
        dumpTexts('drawer when looking for "$siteName"');
      }
      expect(tile, findsOneWidget,
          reason: '$siteName should appear in the drawer');
      await tester.tap(tile);
    }

    // pumpAndSettle deadlocks on a live WebView; instead drive the
    // engine in fixed slices and stop as soon as the predicate
    // matches (or the deadline expires). Polling makes the test
    // tolerant to wide variance in WebView/PaintBinding latency
    // between local chroot runs and the GitHub Actions container.
    Future<void> pumpUntil(
      bool Function() predicate, {
      Duration timeout = const Duration(seconds: 45),
      Duration step = const Duration(milliseconds: 250),
      required String description,
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        if (predicate()) return;
      }
      throw StateError(
          'Timed out after ${timeout.inSeconds}s waiting for: $description');
    }

    await openDrawer();
    await tapSite('Immersive App');
    await pumpUntil(
      () => find.byType(AppBar).evaluate().isEmpty,
      description: 'AppBar to disappear after activating Immersive App',
    );

    expect(find.byType(AppBar), findsNothing,
        reason: 'AppBar should be hidden in fullscreen mode after '
            'activating a site with fullscreenMode=true (FS-003)');
  });
}
