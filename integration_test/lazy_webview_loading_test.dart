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

    Future<void> tapSite(String siteName) async {
      final tile = find.text(siteName);
      if (tile.evaluate().isEmpty) {
        dumpTexts('drawer when looking for "$siteName"');
      }
      expect(tile, findsOneWidget,
          reason: '$siteName should appear in the drawer');
      await tester.tap(tile);
    }

    // pumpAndSettle deadlocks on a live WebView; instead pump in
    // fixed slices and stop as soon as `predicate` matches. Polling
    // makes the test tolerant to wide variance in WebView mount
    // latency between local chroot runs and the GitHub Actions
    // container.
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

    bool hasKey(String siteId) => find
        .byKey(ValueKey(siteId), skipOffstage: false)
        .evaluate()
        .isNotEmpty;

    // LAZY-002 forward + LAZY-003: visiting Lazy A materialises its
    // slot but leaves Lazy B as SizedBox.shrink() (no key). The
    // second-visit half (activate Lazy B → its slot materialises
    // too) was tried but reliably reopening the drawer with a live
    // WebView running is its own integration challenge — keep this
    // test scoped to the forward direction only.
    await openDrawer();
    await tapSite('Lazy A');
    await pumpUntil(
      () => hasKey('lazy-a'),
      description: 'Lazy A slot to materialise',
    );

    expect(find.byKey(const ValueKey('lazy-a'), skipOffstage: false),
        findsOneWidget,
        reason: 'Lazy A slot should materialise after first visit (LAZY-002)');
    expect(find.byKey(const ValueKey('lazy-b'), skipOffstage: false),
        findsNothing,
        reason: 'Lazy B should remain a placeholder until visited (LAZY-003)');
  });
}
