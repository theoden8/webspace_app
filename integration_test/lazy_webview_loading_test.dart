// Lazy webview loading integration test (LAZY-002 / LAZY-003).
//
// Drives the IndexedStack-of-placeholders contract in
// lib/main.dart: the IndexedStack is only rendered once at least one
// site has been visited, and slots for never-visited sites stay as
// `SizedBox.shrink()` placeholders (no `ValueKey(siteId)`). The
// per-slot key is the only public signal that a webview was actually
// constructed for that site, so the test asserts on its presence /
// absence rather than counting `inapp.InAppWebView` widgets directly.
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

    final siteA = WebViewModel(
      siteId: 'lazy-a',
      // RFC 5737 reserved test addresses — won't connect, the
      // assertion is on widget tree shape.
      initUrl: 'http://192.0.2.1/',
      name: 'Lazy A',
    );
    final siteB = WebViewModel(
      siteId: 'lazy-b',
      initUrl: 'http://192.0.2.2/',
      name: 'Lazy B',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(siteA.toJson()),
        jsonEncode(siteB.toJson()),
      ],
    });
  });

  testWidgets('webview slots only materialise after their site is visited',
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

    // LAZY-001: at app start with no site activated, the IndexedStack
    // itself is gated on `_loadedIndices.isNotEmpty` (lib/main.dart),
    // so no per-slot keys are in the tree yet — check including
    // offstage descendants since IndexedStack hides non-visible
    // children behind Offstage.
    expect(find.byKey(const ValueKey('lazy-a'), skipOffstage: false),
        findsNothing,
        reason: 'no site has been visited; site A slot must not exist yet');
    expect(find.byKey(const ValueKey('lazy-b'), skipOffstage: false),
        findsNothing,
        reason: 'no site has been visited; site B slot must not exist yet');

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
      // in fixed slices instead.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    // LAZY-002 forward: visiting Lazy A materialises its slot but
    // leaves Lazy B as SizedBox.shrink() (no key).
    await openDrawer();
    await activateAndPump('Lazy A');

    expect(find.byKey(const ValueKey('lazy-a'), skipOffstage: false),
        findsOneWidget,
        reason: 'Lazy A slot should materialise after first visit (LAZY-002)');
    expect(find.byKey(const ValueKey('lazy-b'), skipOffstage: false),
        findsNothing,
        reason: 'Lazy B should remain a placeholder until visited (LAZY-003)');

    // LAZY-002 second-visit: visiting Lazy B materialises ITS slot.
    // Under container mode (our chroot has WPE WebKit ≥ 2.50), the
    // legacy domain-conflict unload doesn't fire, so Lazy A's slot
    // stays alive too — both keys are present concurrently. Under
    // legacy mode (any future regression that loses container support)
    // LAZY-002 still holds: Lazy B's slot must exist after activation.
    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
    scaffoldState.openDrawer();
    await tester.pumpAndSettle(const Duration(seconds: 5));
    await activateAndPump('Lazy B');

    expect(find.byKey(const ValueKey('lazy-b'), skipOffstage: false),
        findsOneWidget,
        reason: 'Lazy B slot should materialise on first visit (LAZY-002)');
  });
}
