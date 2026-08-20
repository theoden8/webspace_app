// White-screen pixel scenarios (BUG-001), Android emulator/device only.
//
// Drives the historical blank-screen entry paths and asserts on the
// *composited window pixels* over the webview slot via SurfaceDiagPlugin's
// window-level PixelCopy. This is the only capture plane that sees what the
// user sees: Flutter's own screenshot path misses hybrid-composition
// platform views entirely (see screenshot_test.dart's native-screenshot
// workaround), and a JS probe reports the renderer plane, which is healthy
// in every confirmed BUG-001 instance.
//
// Scenario map (docs/bugs/001-white-screen.md):
//   1. Fresh first activation of a site (the 2026-08-13 report: both nudges
//      drain before the initial document commits; no SurfaceDiag coverage).
//   2. Detector sensitivity control: a genuinely white page must classify
//      as uniformBlank, proving the sampler reads webview pixels and the
//      assertions in the other scenarios are not vacuously green.
//   3. Loaded-site switch (_setCurrentIndex reuse path, Attempt 3).
//   4. Reload funnel (reloadAndRepaint + load-settled re-nudge, Attempt 9).
//   5. OS memory pressure against the visible site (Attempt 7).
//   6. Fresh activation with other sites live (controller-attach nudge,
//      Attempt 4).
//   7. Fresh activation of a site whose document commits LATE (PAUSE-025).
//   8. Return from a pushed opaque route (PAUSE-024).
//   9. Nested InAppWebViewScreen: fresh surface on a late-committing
//      document, then the return to the main page (PAUSE-024/025).
//
// Scenarios 1–6 all serve documents that commit in a millisecond, so every
// repaint they exercise lands while the issue-time nudge loop is still
// running. That makes them blind to the ordering every recurrence since
// Attempt 8 has actually been about: a surface that attaches or commits
// AFTER the ~0.6s nudge budget drains. Scenarios 7 and 9 hold the response
// for _kSlowCommit before the first byte, which puts the commit outside that
// budget and leaves the settled-side re-nudge as the only thing that can
// paint it.
//
// Warm start, activity recreation, and back/forward-cache restores need
// real activity lifecycle transitions that an in-process integration test
// cannot produce; those remain an adb-driven tier (see
// openspec/specs/integration-tests/spec.md).
//
// Pages are served from an in-process loopback HTTP server so a network
// failure can never masquerade as a white screen. Each content page is a
// solid color Flutter never draws, so a matching dominant color proves the
// sampled pixels came from the webview, not the app chrome. The server binds
// every IPv4 interface so the same pages are reachable as both 127.0.0.1 and
// 127.0.0.2 — two hosts, one server: a cross-domain navigation (which opens
// the nested screen) that still cannot fail on the network.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

const int _kDarkColor = 0xFF123524;
const int _kMagentaColor = 0xFF8C1D5A;
const int _kBlueColor = 0xFF1D3F8C;

/// How long the slow pages withhold their first byte. Must exceed the nudge
/// loop's budget (`SurfaceRepaintEngine.ticksPerRequest` × 100ms ≈ 0.6s) by
/// enough that every issue-time nudge has drained before the document
/// commits — that is the ordering BUG-001 Attempts 8/9/10 are about.
const Duration _kSlowCommit = Duration(seconds: 3);

String _solidPage(String cssColor, {String body = ''}) =>
    '<!doctype html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<style>html,body{margin:0;height:100%;background:$cssColor;}</style>'
    '</head><body>$body</body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  HttpServer? server;

  setUpAll(() async {
    isDemoMode = true;

    // anyIPv4, not loopbackIPv4: the nested-screen scenario needs a second
    // host name for the same pages (127.0.0.2), because the nested screen
    // opens on a *cross-domain* navigation and getBaseDomain compares IPs
    // literally. Both addresses are loopback, so nothing leaves the device.
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = server!.port;
    final altBase = 'http://127.0.0.2:$port';
    server!.listen((request) async {
      final page = switch (request.uri.path) {
        '/dark.html' => _solidPage('#123524'),
        '/white.html' => _solidPage('#ffffff'),
        '/magenta.html' => _solidPage('#8c1d5a'),
        '/slow-blue.html' => _solidPage('#1d3f8c'),
        // Cross-domain hop into the nested screen, script-initiated so the
        // test never depends on a synthetic touch reaching the platform view.
        // The site that serves it has blockAutoRedirects off, so the
        // navigation decision engine resolves it to blockOpenNested.
        '/opener.html' => _solidPage('#123524',
            body: '<script>setTimeout(function(){'
                "location.href='$altBase/slow-blue.html';"
                '},500);</script>'),
        _ => '<!doctype html><html><body>404</body></html>',
      };
      // Withhold the first byte so the document commits well after every
      // issue-time nudge has drained (see _kSlowCommit).
      if (request.uri.path.startsWith('/slow-')) {
        await Future.delayed(_kSlowCommit);
      }
      request.response
        ..headers.contentType = ContentType.html
        ..write(page);
      request.response.close();
    });
    final base = 'http://127.0.0.1:$port';

    final dark = WebViewModel(
      siteId: 'ws-dark',
      initUrl: '$base/dark.html',
      name: 'Dark',
    );
    final white = WebViewModel(
      siteId: 'ws-white',
      initUrl: '$base/white.html',
      name: 'White',
    );
    final magenta = WebViewModel(
      siteId: 'ws-magenta',
      initUrl: '$base/magenta.html',
      name: 'Magenta',
    );
    final slow = WebViewModel(
      siteId: 'ws-slow',
      initUrl: '$base/slow-blue.html',
      name: 'Slow',
    );
    final opener = WebViewModel(
      siteId: 'ws-opener',
      initUrl: '$base/opener.html',
      name: 'Opener',
      // The hop to 127.0.0.2 is script-initiated and therefore gestureless;
      // the default (block) would classify it blockSilent and never open the
      // nested screen.
      blockAutoRedirects: false,
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(dark.toJson()),
        jsonEncode(white.toJson()),
        jsonEncode(magenta.toJson()),
        jsonEncode(slow.toJson()),
        jsonEncode(opener.toJson()),
      ],
    });
  });

  tearDownAll(() async {
    await server?.close(force: true);
  });

  bool colorNear(int? actual, int expected, {int tolerance = 28}) {
    if (actual == null) return false;
    for (final shift in const [16, 8, 0]) {
      final a = (actual >> shift) & 0xFF;
      final e = (expected >> shift) & 0xFF;
      if ((a - e).abs() > tolerance) return false;
    }
    return true;
  }

  // The test data is synthetic (loopback URLs, seeded names), so dumping the
  // sensitive log ring into the CI log leaks nothing; it is the only way to
  // read onLoadStop/onReceivedError from a remote failure (INTEG-006).
  void dumpDiagnostics(WidgetTester tester, String context) {
    print('=== white_screen_test failure: $context');
    print('Texts: ${find.byType(Text).evaluate().map((e) {
      final w = e.widget;
      return w is Text ? (w.data ?? '?') : '?';
    }).take(30).toList()}');
    final entries = LogService.instance.allEntriesMerged;
    for (final e in entries.skip(entries.length < 60 ? 0 : entries.length - 60)) {
      print('  [${e.tag}/${e.level.name}] ${e.message}');
    }
  }

  Future<WindowRegionSample> sampleSlot(WidgetTester tester, Finder slot) {
    final logical = tester.getRect(slot.first);
    return SurfaceDiagNative.sampleWindowRegion(SurfaceDiagNative.physicalRect(
      logicalRect: logical,
      devicePixelRatio: tester.view.devicePixelRatio,
      insetLogical: 12,
    ));
  }

  // pumpAndSettle deadlocks on a live webview (see lazy_webview_loading_test),
  // so poll in fixed slices, re-sampling the composited window each pass
  // until the sample is accepted or the deadline passes. On timeout the last
  // sample is the diagnostic: uniform white with an ok status IS a white
  // screen.
  Future<WindowRegionSample> pollSlot(
    WidgetTester tester,
    Finder slot,
    String description,
    bool Function(WindowRegionSample) accept, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    WindowRegionSample? last;
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (slot.evaluate().isEmpty) continue;
      last = await sampleSlot(tester, slot);
      if (accept(last)) {
        print('white_screen_test: $description -> $last');
        return last;
      }
    }
    dumpDiagnostics(tester, '$description; last sample: $last');
    fail('Timed out after ${timeout.inSeconds}s waiting for: $description '
        '(last sample: $last)');
  }

  Future<WindowRegionSample> pollSite(
    WidgetTester tester,
    String siteId,
    String description,
    bool Function(WindowRegionSample) accept, {
    Duration timeout = const Duration(seconds: 90),
  }) =>
      pollSlot(tester, find.byKey(ValueKey(siteId)), description, accept,
          timeout: timeout);

  Future<void> openSiteDrawer(WidgetTester tester) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (find.byType(Drawer).evaluate().isNotEmpty) return;
      final menuIcon = find.byIcon(Icons.menu);
      if (menuIcon.evaluate().isNotEmpty) {
        await tester.tap(menuIcon.first);
      } else {
        final scaffolds = find.byType(Scaffold).evaluate();
        for (final element in scaffolds) {
          final state = tester.state<ScaffoldState>(
              find.byWidget(element.widget as Scaffold));
          if (state.hasDrawer) {
            state.openDrawer();
            break;
          }
        }
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byType(Drawer), findsOneWidget,
        reason: 'site drawer should open for switching sites');
  }

  // The active site's name can also appear in the AppBar title, so scope to
  // the open drawer when there is one; the drawer tile is the switch target.
  Future<void> tapSite(WidgetTester tester, String siteName) async {
    final drawer = find.byType(Drawer);
    final tile = drawer.evaluate().isNotEmpty
        ? find.descendant(of: drawer, matching: find.text(siteName))
        : find.text(siteName);
    if (tile.evaluate().isEmpty) {
      dumpDiagnostics(tester, 'site tile "$siteName" not found');
    }
    expect(tile, findsWidgets,
        reason: '$siteName should be visible in the site list');
    await tester.tap(tile.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  // Tap an action in the AppBar's overflow popup menu. Menu contents are
  // built at open time and some entries are conditional (Refresh swaps to
  // Stop while a load is in flight), so an absent action means dismiss and
  // reopen until it appears. The action's icon is unique to the open menu:
  // the AppBar renders its own gear only on the webspaces list, where no
  // site is active.
  Future<void> openOverflowMenuAction(
    WidgetTester tester,
    IconData action,
    String label, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        dumpDiagnostics(tester, '$label: overflow menu action not reachable');
        fail('$label: timed out opening the overflow menu / finding the action');
      }
      final item = find.byIcon(action);
      if (item.evaluate().isNotEmpty) {
        await tester.tap(item.first);
        await tester.pump();
        return;
      }
      if (find.byType(PopupMenuItem<String>).evaluate().isNotEmpty) {
        // Menu is open without the action: dismiss and reopen next pass.
        await tester.tapAt(const Offset(5, 5));
      } else {
        final menuButton = find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(PopupMenuButton<String>));
        if (menuButton.evaluate().isNotEmpty) {
          await tester.tap(menuButton.first);
        }
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets(
    'BUG-001 entry paths keep the composited webview pixels non-blank',
    (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      bool darkVisible(WindowRegionSample s) =>
          s.ok &&
          colorNear(s.dominantColor, _kDarkColor) &&
          (s.uniformFraction ?? 0) > 0.5;

      // Scenario 1: fresh first activation. This is the reported path: the
      // webview is created from scratch, both the activation and the
      // controller-attach nudges drain before the initial document commits,
      // and no settled-side nudge exists for a first load. The window must
      // still end up showing the page.
      await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tapSite(tester, 'Dark');
      await pollSite(tester, 'ws-dark',
          'scenario 1: fresh activation paints dark content', darkVisible);

      // Scenario 2: detector sensitivity control. A genuinely white page is
      // pixel-identical to the BUG-001 blank, so the sampler MUST classify it
      // uniformBlank; if this fails, every other scenario is vacuous.
      // Require actual near-white pixels, not just the blank verdict: the
      // first emulator run showed the pre-composite platform-view hole
      // samples as uniform 0x00000000 (alpha 0), which also classifies
      // blank; waiting for white proves the white *content* composited.
      await openSiteDrawer(tester);
      await tapSite(tester, 'White');
      await pollSite(
          tester,
          'ws-white',
          'scenario 2: white control page classifies as uniformBlank',
          (s) =>
              s.ok &&
              colorNear(s.dominantColor, 0xFFFFFFFF) &&
              SurfaceDiagNative.classify(s) == WindowSampleVerdict.uniformBlank);

      // Scenario 3: switch back to an already-loaded site (_setCurrentIndex
      // reuse path, Attempt 3's chokepoint).
      await openSiteDrawer(tester);
      await tapSite(tester, 'Dark');
      await pollSite(tester, 'ws-dark',
          'scenario 3: loaded-site switch repaints dark content', darkVisible);

      // Scenario 4: reload funnel (Attempt 9). The Refresh action lives
      // inside the AppBar's overflow popup menu (it swaps to Stop while
      // loading), so the icon only exists in the tree while the menu is
      // open: open the menu, tap Refresh, then require the recommitted
      // document on the window. Menu contents are built at open time, so a
      // menu showing Stop is dismissed and reopened until the load settles.
      await openOverflowMenuAction(tester, Icons.refresh, 'scenario 4');
      await pollSite(tester, 'ws-dark',
          'scenario 4: reload recommits dark content', darkVisible);

      // Scenario 5: OS memory pressure with the site visible (Attempt 7).
      // Delivered as the real platform message so it flows through
      // ServicesBinding into didHaveMemoryPressure. The active site is
      // hard-protected from eviction; the probe + nudge recovery must leave
      // its pixels intact.
      ServicesBinding.instance.channelBuffers.push(
        'flutter/system',
        const JSONMessageCodec()
            .encodeMessage(<String, dynamic>{'type': 'memoryPressure'}),
        (_) {},
      );
      await tester.pump();
      await pollSite(tester, 'ws-dark',
          'scenario 5: memory pressure keeps dark content', darkVisible);

      // Scenario 6: fresh activation while other webviews are live
      // (controller-attach nudge, Attempt 4's chokepoint).
      await openSiteDrawer(tester);
      await tapSite(tester, 'Magenta');
      await pollSite(
          tester,
          'ws-magenta',
          'scenario 6: fresh activation among live sites paints magenta',
          (s) =>
              s.ok &&
              colorNear(s.dominantColor, _kMagentaColor) &&
              (s.uniformFraction ?? 0) > 0.5);

      bool blueVisible(WindowRegionSample s) =>
          s.ok &&
          colorNear(s.dominantColor, _kBlueColor) &&
          (s.uniformFraction ?? 0) > 0.5;

      // Scenario 7: fresh activation of a site whose document commits LATE
      // (PAUSE-025, bug doc gap #7). Every scenario above serves instantly, so
      // its commit lands inside the activation/controller-attach nudge loops
      // and any of them would repaint it. Here the surface attaches, both
      // nudges drain against a surface with nothing on it, and only then does
      // the document commit — so the settled-side re-nudge is the only thing
      // that can paint it. The deadline is deliberately tight: a blank that
      // clears minutes later, on some unrelated relayout, is still the bug.
      await openSiteDrawer(tester);
      await tapSite(tester, 'Slow');
      await pollSlot(
          tester,
          find.byKey(const ValueKey('ws-slow')),
          'scenario 7: late-committing first document paints blue',
          blueVisible,
          timeout: const Duration(seconds: 45));

      // Scenario 8: return from a pushed opaque route (PAUSE-024). While the
      // settings page covers the webview its platform view is not composited,
      // so Android detaches the SurfaceView and re-attaches it on the pop —
      // through no other chokepoint: same site, same controller, no
      // navigation, no lifecycle event.
      await openOverflowMenuAction(tester, Icons.settings, 'scenario 8');
      final settlesSettings = DateTime.now().add(const Duration(seconds: 20));
      while (find.byType(SettingsScreen).evaluate().isEmpty &&
          DateTime.now().isBefore(settlesSettings)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(SettingsScreen), findsOneWidget,
          reason: 'the site settings route should cover the webview');
      // Nothing was edited, so PopScope lets the back button pop directly.
      await tester.tap(find
          .descendant(
              of: find.byType(SettingsScreen), matching: find.byType(BackButton))
          .first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await pollSlot(
          tester,
          find.byKey(const ValueKey('ws-slow')),
          'scenario 8: returning from a pushed route repaints the surface',
          blueVisible,
          timeout: const Duration(seconds: 45));

      // Scenario 9: the nested InAppWebViewScreen. Its cross-domain entry
      // mounts a brand-new SurfaceView on a late-committing document — the
      // PAUSE-017 + PAUSE-025 pair, neither of which the nested screen had
      // before, and which the main page's nudge cannot reach (that one
      // toggles an inset around an IndexedStack sitting under this route).
      await openSiteDrawer(tester);
      await tapSite(tester, 'Opener');
      final nestedDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (find.byType(InAppWebViewScreen).evaluate().isEmpty &&
          DateTime.now().isBefore(nestedDeadline)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      if (find.byType(InAppWebViewScreen).evaluate().isEmpty) {
        dumpDiagnostics(tester, 'scenario 9: nested screen never opened');
      }
      expect(find.byType(InAppWebViewScreen), findsOneWidget,
          reason: 'the cross-domain hop should open the nested webview screen');
      await pollSlot(
          tester,
          find.byKey(const ValueKey(kNestedWebViewSlotKey)),
          'scenario 9: nested fresh surface paints its late document',
          blueVisible,
          timeout: const Duration(seconds: 45));

      // ...and popping back to the main page re-attaches the opener's
      // surface, the nested half of PAUSE-024. The nested AppBar's leading is
      // a custom IconButton (it pops directly, bypassing PopScope), not a
      // BackButton, so match its icon.
      await tester.tap(find
          .descendant(
              of: find.byType(InAppWebViewScreen),
              matching: find.byType(BackButtonIcon))
          .first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await pollSlot(
          tester,
          find.byKey(const ValueKey('ws-opener')),
          'scenario 9: returning from the nested screen repaints the site',
          darkVisible,
          timeout: const Duration(seconds: 45));
    },
    skip: !Platform.isAndroid,
    // Stays under the wrapper script's 25m wall-clock cap, which also has to
    // cover the debug build and install: a Dart-level timeout names the
    // scenario that hung, a killed process does not.
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
