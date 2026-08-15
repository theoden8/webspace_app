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
//
// Warm start, activity recreation, and back/forward-cache restores need
// real activity lifecycle transitions that an in-process integration test
// cannot produce; those remain an adb-driven tier (see
// openspec/specs/integration-tests/spec.md).
//
// Pages are served from an in-process loopback HTTP server so a network
// failure can never masquerade as a white screen. Each content page is a
// solid color Flutter never draws, so a matching dominant color proves the
// sampled pixels came from the webview, not the app chrome.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/surface_diag_native.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

const int _kDarkColor = 0xFF123524;
const int _kMagentaColor = 0xFF8C1D5A;

String _solidPage(String cssColor) => '<!doctype html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<style>html,body{margin:0;height:100%;background:$cssColor;}</style>'
    '</head><body></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  HttpServer? server;

  setUpAll(() async {
    isDemoMode = true;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) {
      final page = switch (request.uri.path) {
        '/dark.html' => _solidPage('#123524'),
        '/white.html' => _solidPage('#ffffff'),
        '/magenta.html' => _solidPage('#8c1d5a'),
        _ => '<!doctype html><html><body>404</body></html>',
      };
      request.response
        ..headers.contentType = ContentType.html
        ..write(page);
      request.response.close();
    });
    final base = 'http://127.0.0.1:${server!.port}';

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
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(dark.toJson()),
        jsonEncode(white.toJson()),
        jsonEncode(magenta.toJson()),
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

  Future<WindowRegionSample> sampleSite(WidgetTester tester, String siteId) {
    final logical = tester.getRect(find.byKey(ValueKey(siteId)).first);
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
  Future<WindowRegionSample> pollSite(
    WidgetTester tester,
    String siteId,
    String description,
    bool Function(WindowRegionSample) accept, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    WindowRegionSample? last;
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byKey(ValueKey(siteId)).evaluate().isEmpty) continue;
      last = await sampleSite(tester, siteId);
      if (accept(last)) {
        print('white_screen_test: $description -> $last');
        return last;
      }
    }
    dumpDiagnostics(tester, '$description; last sample: $last');
    fail('Timed out after ${timeout.inSeconds}s waiting for: $description '
        '(last sample: $last)');
  }

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
      final refreshDeadline = DateTime.now().add(const Duration(seconds: 45));
      var refreshTapped = false;
      while (!refreshTapped) {
        if (DateTime.now().isAfter(refreshDeadline)) {
          dumpDiagnostics(tester, 'scenario 4: Refresh menu action not reachable');
          fail('Timed out opening the overflow menu / finding Refresh');
        }
        final refresh = find.byIcon(Icons.refresh);
        if (refresh.evaluate().isNotEmpty) {
          await tester.tap(refresh.first);
          await tester.pump();
          refreshTapped = true;
          break;
        }
        final menuOpen =
            find.byType(PopupMenuItem<String>).evaluate().isNotEmpty;
        if (menuOpen) {
          // Menu is open but shows Stop: dismiss and reopen next pass.
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
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
