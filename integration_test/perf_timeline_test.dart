// Perf-visibility trend (DEVTOOLS-013): boot the app and switch between
// local pages so the real engine emits its "Launch, from main():" and
// "Switch:" App-logs lines. The CI tiers grep these into a device-numbers
// artifact; there is no gate, so this test only proves the lines appear and
// reprints them under a marker. It names no site and keeps nothing (ARCH-001).
//
// Offline by construction: both pages are served from a loopback socket, so
// the egress-guarded Linux tier and the emulator reach them without the
// network, and the page loads settle in milliseconds rather than riding on a
// real site's latency (which a trend must not fold in).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'fixture_server.dart';
import 'helpers/ui.dart';

/// The one token the CI step greps out of the per-test log. Keeping the
/// emitted lines behind a marker of our own means the capture does not depend
/// on LogService's console prefix.
const _marker = 'WS_PERF_TIMELINE';

String _page(String title) =>
    '<!doctype html><html><head><meta charset="utf-8"><title>$title</title>'
    '</head><body><h1>$title</h1></body></html>';

/// The startup lines the timeline owns, oldest first.
List<String> _timelineLines() => [
      for (final e
          in LogService.instance.recent({LogTag.startup}, limit: 40, scan: 400))
        if (e.message.startsWith('Launch, from main():') ||
            e.message.startsWith('Switch:'))
          e.message,
    ];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Draw frames on the real clock so the live webview and the startup flow run
  // during the RealWait loops below (a live webview never lets pumpAndSettle
  // return). Same policy the screenshot tour uses.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  late HttpServer server;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, onEvent: (HttpRequest req) {
      final res = req.response..headers.set('Cache-Control', 'no-store');
      res
        ..headers.contentType = ContentType.html
        ..write(_page(req.uri.path));
      unawaited(res.close());
    });
  });

  tearDownAll(() async => server.close(force: true));

  testWidgets('cold start then site switches emit timeline lines (DEVTOOLS-013)',
      (tester) async {
    final base = 'http://127.0.0.1:${server.port}';
    // isDemoMode keeps the seed out of the host's real storage.
    isDemoMode = true;
    // Three loopback sites and the legacy drawer, so a switch is a tap in a
    // list the build renders the same way whichever design is default. Seeded
    // by hand (not seedDemoData, whose sites are real URLs) to stay offline.
    final sites = [
      WebViewModel(initUrl: '$base/alpha', name: 'Alpha'),
      WebViewModel(initUrl: '$base/beta', name: 'Beta'),
      WebViewModel(initUrl: '$base/gamma', name: 'Gamma'),
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      'legacyDesign': true,
      'webViewModels': [for (final s in sites) jsonEncode(s.toJson())],
      'webspaces': [jsonEncode(Webspace.all().toJson())],
    });

    app.main();
    await tester.pump();
    // The launch segment ends once the page settles or stops being waited for;
    // 25s is generous for the slow runner. A live webview means pumpAndSettle
    // never returns, so the wait is on the real clock.
    const waitReal = RealWait(interval: Duration(milliseconds: 300));
    await waitReal(
      tester,
      timeout: const Duration(seconds: 25),
      done: () => _timelineLines().any((l) => l.startsWith('Launch')),
      label: 'launch line emitted',
    );

    // One site switch, then a second, each a real activate() whose `tap`
    // origin opens a Switch segment and whose first-load settle closes it.
    // Two switches so at least one targets a never-visited site (a full line
    // with every phase) whichever one the launch opened.
    //
    // Tolerant on purpose: this rides the gated build tiers, and a trend must
    // never fail their gate. So the drawer and the tile are reached without an
    // assertion, a missing one is skipped, and only the Launch line (the proof
    // the app booted) is checked at the end.
    Future<void> openDrawer() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (find.byType(Drawer).evaluate().isNotEmpty) return;
        final menu = find.byIcon(Icons.menu);
        if (menu.evaluate().isNotEmpty) {
          await tester.tap(menu.first);
        } else {
          for (final element in find.byType(Scaffold).evaluate()) {
            final state = tester
                .state<ScaffoldState>(find.byWidget(element.widget as Scaffold));
            if (state.hasDrawer) {
              state.openDrawer();
              break;
            }
          }
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    Future<void> switchTo(String name, {required int untilSwitchLines}) async {
      await openDrawer();
      final drawer = find.byType(Drawer);
      final tile = drawer.evaluate().isNotEmpty
          ? find.descendant(of: drawer, matching: find.text(name))
          : find.text(name);
      if (tile.evaluate().isEmpty) return; // skip, do not fail the gate
      await tester.tap(tile.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await waitReal(
        tester,
        timeout: const Duration(seconds: 25),
        done: () =>
            _timelineLines().where((l) => l.startsWith('Switch:')).length >=
            untilSwitchLines,
        label: 'switch to $name settled',
      );
    }

    await switchTo('Beta', untilSwitchLines: 1);
    await switchTo('Gamma', untilSwitchLines: 2);

    final lines = _timelineLines();
    for (final line in lines) {
      // Already console-logged by LogService; reprinted under the marker so
      // the CI capture is a plain grep independent of the log prefix.
      debugPrint('$_marker $line');
    }

    // The only hard check: the app booted and reported its launch. Anything
    // less is a real regression, not a trend wobble. Switch lines are a trend,
    // not a gate, so a run that misses one still passes and still publishes
    // what it captured.
    expect(lines.any((l) => l.startsWith('Launch, from main():')), isTrue,
        reason: 'the launch timeline line must be emitted on cold start');
  });
}
