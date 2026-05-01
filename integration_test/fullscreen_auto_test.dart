// Per-site auto-fullscreen integration test (FS-003).
//
// Activating a site whose `fullscreenMode = true` SHALL hide the
// AppBar (the visible signal of `_isFullscreen` — see
// lib/main.dart `_enterFullscreen` / `_exitFullscreen`). Switching to
// a site with `fullscreenMode = false` exits fullscreen and the
// AppBar reappears.
//
// Two sites are pre-seeded so the test can drive a switch between
// them and observe both transitions in one run. Site activation
// triggers a real WebView mount; the wayland + WEBKIT_DISABLE_SANDBOX
// chroot harness is required (see openspec/specs/integration-tests/spec.md).

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
    final normal = WebViewModel(
      siteId: 'normal-1',
      initUrl: 'http://192.0.2.2/',
      name: 'Normal App',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(immersive.toJson()),
        jsonEncode(normal.toJson()),
      ],
    });
  });

  testWidgets(
      'activating a fullscreenMode site hides the AppBar; switching back shows it',
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

    Future<void> activateAndPump(String siteName) async {
      final tile = find.text(siteName);
      if (tile.evaluate().isEmpty) {
        dumpTexts('drawer when looking for "$siteName"');
      }
      expect(tile, findsOneWidget,
          reason: '$siteName should appear in the drawer');
      await tester.tap(tile);
      // pumpAndSettle deadlocks on a live WebView; drive the engine
      // in fixed slices instead so onControllerCreated fires +
      // _enterFullscreen / _exitFullscreen run.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    await openDrawer();
    await activateAndPump('Immersive App');

    expect(find.byType(AppBar), findsNothing,
        reason: 'AppBar should be hidden in fullscreen mode after '
            'activating a site with fullscreenMode=true (FS-003)');

    // Switch to the non-fullscreen site. The drawer is gone; reopen
    // it via the All-webspace tile is impossible while fullscreen
    // (no AppBar), so use the Scaffold drawer directly via gesture
    // — but the simpler path is the long-press exit handle: tap the
    // top edge to exit fullscreen first, then open the drawer
    // through the regular flow.
    //
    // Instead of re-driving the entire UI, the simplest assertion
    // for the inverse half is via webspace switching: tapping the
    // All-webspace tile from outside the drawer would be ideal, but
    // the AppBar is hidden — so emulate the user dragging to expose
    // the Scaffold drawer through ScaffoldState.openDrawer().
    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    await activateAndPump('Normal App');

    expect(find.byType(AppBar), findsWidgets,
        reason: 'AppBar should reappear after switching to a site '
            'with fullscreenMode=false (FS-003 inverse)');
  });
}
