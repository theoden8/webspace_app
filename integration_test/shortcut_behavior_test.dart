// Home-shortcut behavior scenarios (openspec/specs/home-shortcut/spec.md),
// Android emulator/device only.
//
// The resolution rules themselves (StartupRestoreEngine.resolveLaunch, the
// ledger reconcile, the effective-pinned widening) are unit-tested in
// test/startup_restore_engine_test.dart. What no headless test reaches is the
// *wiring* in lib/main.dart: which prompt a resolution raises, what the user's
// answer persists, whether the menu item is offered, and what the delete flow
// does with the launcher tiles that still point at the site. That is what this
// suite drives, through the real widget tree.
//
// Scenario map (requirement -> test):
//   HS-002 / HS-006  cold launch selects the site and drops currentUrl to
//                    initUrl (the pinned entry point, not last session's drift)
//   HS-005 / HS-004  "Home Shortcut" hidden for a pinned site, shown for an
//                    unpinned one, hidden for a site an orphaned tile was
//                    rebound to
//   HS-001 / HS-012  tapping the item pins through the channel and records the
//                    site's url in the ledger
//   HS-011           orphaned tile with a domain match: cancel leaves no trace,
//                    confirm opens and is remembered, the next tap is silent
//   HS-011           orphaned tile with no match: reroute to an existing site,
//                    or create a new one for the ledger url
//   HS-013           deleting a site reachable by pinned tiles prompts
//                    Keep/Reassign/Disable; Disable disables every reaching
//                    tile and drops its ledger + rebind entries; deleting an
//                    unreachable site prompts nothing
//
// The platform channel is mocked (a real launcher pin dialog is not drivable
// from in-process), and the mock drains `getLaunchSiteId` on read exactly like
// MainActivity's `intent.removeExtra`, so a re-poll on the next resume sees
// nothing. Pages come from an in-process loopback server so a site activation
// settles without network. The genuinely out-of-process half — a launcher tap
// delivering a real intent to a running activity — lives in the adb tier
// (scripts/run_android_lifecycle_tests.sh, INTEG-013).

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
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

const _kShortcutChannel = MethodChannel(
  'org.codeberg.theoden8.webspace/shortcuts',
);

// Unreachable RFC 5737 test addresses: used only as ledger urls, so their base
// domain differs from the loopback sites and no connection is ever needed.
const _kOffDomainUrl = 'http://192.0.2.9/gone.html';
const _kCreateUrl = 'http://192.0.2.10/fresh.html';

String _solidPage(String cssColor) =>
    '<!doctype html><html><head>'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<style>html,body{margin:0;height:100%;background:$cssColor;}</style>'
    '</head><body></body></html>';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  HttpServer? server;
  late String hostA;
  late String hostB;

  // Mock launcher state. `pendingLaunch` is what the next `getLaunchSiteId`
  // returns; reading it clears it, mirroring the native consume-on-read.
  String? pendingLaunch;
  var pinned = <String>{};
  final calls = <MethodCall>[];

  setUpAll(() async {
    isDemoMode = true;

    // anyIPv4 so both loopback names below reach the same server.
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server!.listen((request) {
      final page = switch (request.uri.path) {
        '/a.html' => _solidPage('#123524'),
        '/b.html' => _solidPage('#1d3f8c'),
        '/deep.html' => _solidPage('#8c1d5a'),
        _ => null,
      };
      final response = request.response;
      if (page == null) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.headers.contentType = ContentType.html;
        response.write(page);
      }
      response.close();
    });
    hostA = 'http://127.0.0.1:${server!.port}';
    hostB = 'http://localhost:${server!.port}';

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kShortcutChannel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getLaunchSiteId':
              final launch = pendingLaunch;
              pendingLaunch = null;
              return launch;
            case 'getPinnedSiteIds':
              return pinned.toList();
            case 'pinShortcut':
              pinned.add((call.arguments as Map)['siteId'] as String);
              return true;
            case 'disableShortcut':
              pinned.remove((call.arguments as Map)['siteId'] as String);
              return null;
            default:
              // removeShortcut, syncSites, getDiagSeed, isAppIntentsSupported.
              return call.method == 'isAppIntentsSupported' ? false : null;
          }
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kShortcutChannel, null);
    await server?.close(force: true);
  });

  WebViewModel siteA({String? currentUrl}) => WebViewModel(
    siteId: 'ws-hs-a',
    initUrl: '$hostA/a.html',
    currentUrl: currentUrl,
    name: 'Site A',
  );
  WebViewModel siteB() =>
      WebViewModel(siteId: 'ws-hs-b', initUrl: '$hostB/b.html', name: 'Site B');

  /// Seed the app's persisted state plus the mock launcher's pin set. Called
  /// before every `app.main()`; `setMockInitialValues` nullifies the
  /// SharedPreferences singleton, so each run starts from exactly this state.
  void seed({
    required List<WebViewModel> sites,
    Map<String, String> ledger = const {},
    Map<String, String> remap = const {},
    Set<String> pinnedTiles = const {},
    String? launch,
  }) {
    SharedPreferences.setMockInitialValues({
      'webViewModels': [for (final s in sites) jsonEncode(s.toJson())],
      // A shortcut launch enters fullscreen by default (FS-008), which hides
      // the app bar the menu assertions need.
      'fullscreenOnShortcut': false,
      'shortcutUrlLedger': jsonEncode(ledger),
      'shortcutSiteRemap': jsonEncode(remap),
    });
    pinned = {...pinnedTiles};
    calls.clear();
    pendingLaunch = launch;
  }

  void dumpDiagnostics(String context) {
    // Test data is synthetic (loopback urls, seeded names), so the log ring is
    // safe to print and is the only view of the resolution path (INTEG-006).
    // ignore: avoid_print
    print('=== shortcut_behavior_test: $context');
    // ignore: avoid_print
    print(
      'Texts: ${find.byType(Text).evaluate().map((e) {
        final w = e.widget;
        return w is Text ? (w.data ?? '?') : '?';
      }).take(40).toList()}',
    );
    final entries = LogService.instance.allEntriesMerged;
    for (final e in entries.skip(
      entries.length < 40 ? 0 : entries.length - 40,
    )) {
      // ignore: avoid_print
      print('  [${e.tag}/${e.level.name}] ${e.message}');
    }
  }

  // pumpAndSettle deadlocks once a webview is live (see
  // lazy_webview_loading_test), so every wait polls in fixed slices instead.
  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    final deadline = DateTime.now().add(total);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpUntilAsync(
    WidgetTester tester,
    Future<bool> Function() predicate, {
    required String description,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (await predicate()) return;
    }
    dumpDiagnostics('timed out waiting for $description');
    fail('Timed out after ${timeout.inSeconds}s waiting for: $description');
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() predicate, {
    required String description,
    Duration timeout = const Duration(seconds: 45),
  }) => pumpUntilAsync(
    tester,
    () async => predicate(),
    description: description,
    timeout: timeout,
  );

  /// Boot a fresh app instance, run [body] against it, then unmount the tree
  /// before the next test's `app.main()` can see it.
  ///
  /// The teardown is the point: leaving the outgoing tree mounted made the
  /// incoming `MaterialApp` collide with it over the `ScaffoldMessenger`
  /// GlobalKey, which truncates the widget tree, and unmounting a tree that
  /// owns a live `InAppWebView` throws from the plugin's own dispose path
  /// (`AndroidPullToRefreshController` disposing its channel twice). Both are
  /// artifacts of restarting the app inside one test process — neither is a
  /// path production can take — so errors are swallowed for the teardown
  /// window only, and the next test starts from an empty root.
  Future<void> withApp(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    app.main();
    // Settles the home screen (no webview is mounted until a site activates,
    // and a shortcut cold launch mounts one — hence the slice-pump fallback).
    await pumpFor(tester, const Duration(seconds: 5));
    try {
      await body();
      // Let anything the last action left in flight drain before the tree goes
      // away: an app handler that resumes after its widget is gone throws on
      // the first `context` it touches (observed as `Navigator.pop` inside
      // `_deleteSite` failing its null check). Tests that can name their own
      // completion signal should still wait on it; this is the backstop.
      await pumpFor(tester, const Duration(seconds: 2));
    } finally {
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (_) {};
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpFor(tester, const Duration(milliseconds: 500));
      FlutterError.onError = previousOnError;
      tester.takeException();
    }
  }

  List<WebViewModel> models() => app.debugWebViewModels ?? const [];

  bool siteIsMounted(String siteId) =>
      find.byKey(ValueKey(siteId), skipOffstage: false).evaluate().isNotEmpty;

  Future<Map<String, dynamic>> prefsMap(String key) async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null || raw.isEmpty) return {};
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  /// Re-foreground the running app, optionally parking a pending launch first
  /// — the `didChangeAppLifecycleState(resumed)` a launcher tap produces, and
  /// the event `_onResumed` -> `_handleShortcutIntent` hangs off.
  ///
  /// The round trip goes through `inactive`, never `paused`/`hidden`:
  /// `SchedulerBinding` sets `framesEnabled = false` for those two, which makes
  /// `scheduleFrame()` a no-op, so the next `tester.pump()` waits forever for a
  /// frame nobody will schedule (observed as a 25-minute CI hang). The real
  /// background/foreground cycle, with the pause work in between, is driven
  /// out of process by the adb tier.
  Future<void> resumeApp(WidgetTester tester, {String? withLaunch}) async {
    pendingLaunch = withLaunch;
    Future<void> send(String state) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/lifecycle',
          const StringCodec().encodeMessage('AppLifecycleState.$state'),
          (_) {},
        );
    await send('inactive');
    await send('resumed');
    await tester.pump();
  }

  Future<void> openOverflowMenu(WidgetTester tester) async {
    final button = find.byType(PopupMenuButton<String>);
    expect(
      button,
      findsWidgets,
      reason: 'the site view should expose an overflow menu',
    );
    await tester.tap(button.last);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      find.text('Settings'),
      findsWidgets,
      reason: 'the overflow menu should be open',
    );
  }

  bool drawerIsOpen() => find.byType(Drawer).evaluate().isNotEmpty;

  Future<void> openSiteDrawer(WidgetTester tester) async {
    if (drawerIsOpen()) return;
    // Tapping the already-selected webspace tile opens the drawer (the
    // same-id branch of _selectWebspace).
    await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
    await pumpFor(tester, const Duration(seconds: 2));
    expect(
      find.byType(Drawer),
      findsOneWidget,
      reason: 'the site drawer should open',
    );
  }

  /// Wait out a deletion: `_deleteSite` closes the drawer as its very last
  /// statement, so a closed drawer is the signal that its whole async tail
  /// (storage sweeps, cache deletes, the HS-013 prompt) has drained. Without
  /// this the test can finish while the tail is still running, and tearing the
  /// tree down under it throws from that final `Navigator.pop`.
  Future<void> waitForDeleteToSettle(WidgetTester tester) => pumpUntil(
    tester,
    () => !drawerIsOpen(),
    description: 'the deletion to finish and close the drawer',
    timeout: const Duration(seconds: 60),
  );

  Future<void> tapDialogButton(WidgetTester tester, String label) async {
    final button = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(label),
    );
    if (button.evaluate().isEmpty) dumpDiagnostics('no "$label" in the dialog');
    expect(button, findsOneWidget, reason: 'dialog should offer "$label"');
    await tester.tap(button);
    await pumpFor(tester, const Duration(seconds: 1));
  }

  // The shortcut paths in lib/main.dart are Platform.isAndroid-gated; the
  // desktop integration loops skip this file by basename as well.
  final skipOffAndroid = !Platform.isAndroid;

  testWidgets(
    'cold launch opens the pinned site at its initUrl (HS-002 / HS-006)',
    (tester) async {
      seed(
        sites: [
          siteA(currentUrl: '$hostA/deep.html'),
          siteB(),
        ],
        pinnedTiles: {'ws-hs-a'},
        launch: 'ws-hs-a',
      );
      await withApp(tester, () async {
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-a'),
          description: 'the launched site to activate',
        );
        final launched = models().firstWhere((m) => m.siteId == 'ws-hs-a');
        expect(
          launched.currentUrl,
          launched.initUrl,
          reason:
              'a shortcut launch is the pinned entry point, so last '
              'session\'s drift must be dropped (HS-006)',
        );
        expect(
          siteIsMounted('ws-hs-b'),
          isFalse,
          reason: 'only the launched site should be activated',
        );

        // HS-012: on the initState/resume cadence the ledger records the url of
        // every pinned site that still exists, so a later deletion leaves a
        // routable trail. Asserted after a resume because the initState pass
        // races `_restoreAppState` for the loaded model list.
        await resumeApp(tester);
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutUrlLedger'))['ws-hs-a'] ==
              '$hostA/a.html',
          description: 'the startup ledger reconcile to record the pinned url',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'the Home Shortcut item hides for a pinned site (HS-005)',
    (tester) async {
      seed(
        sites: [siteA(), siteB()],
        pinnedTiles: {'ws-hs-a'},
        launch: 'ws-hs-a',
      );
      await withApp(tester, () async {
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-a'),
          description: 'the pinned site to activate',
        );

        await openOverflowMenu(tester);
        expect(
          find.text('Home Shortcut'),
          findsNothing,
          reason:
              'the site already has a pinned tile, so pinning a second '
              'one must not be offered',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'the Home Shortcut item hides for a site an orphaned tile was rebound to '
    '(HS-005)',
    (tester) async {
      // A tile whose own site is gone, rebound to Site B by an earlier
      // HS-011 prompt: B is already reachable from the launcher.
      seed(
        sites: [siteA(), siteB()],
        remap: {'ws-hs-ghost': 'ws-hs-b'},
        pinnedTiles: {'ws-hs-ghost'},
        launch: 'ws-hs-b',
      );
      await withApp(tester, () async {
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-b'),
          description: 'the rebound site to activate',
        );

        await openOverflowMenu(tester);
        expect(
          find.text('Home Shortcut'),
          findsNothing,
          reason: 'an existing tile already reaches this site',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'pinning an unpinned site goes through the channel and records the ledger '
    '(HS-004 / HS-001 / HS-012)',
    (tester) async {
      seed(sites: [siteA(), siteB()], launch: 'ws-hs-a');
      await withApp(tester, () async {
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-a'),
          description: 'the launched site to activate',
        );

        await openOverflowMenu(tester);
        expect(
          find.text('Home Shortcut'),
          findsOneWidget,
          reason: 'an unpinned site should offer the menu item on Android',
        );
        await tester.tap(find.text('Home Shortcut'));

        // The favicon is rasterized before the pin (HS-003), which reaches the
        // loopback server first — poll rather than assume a settled frame.
        await pumpUntil(
          tester,
          () => calls.any((c) => c.method == 'pinShortcut'),
          description: 'the pin request to reach the platform channel',
        );
        final pin = calls.lastWhere((c) => c.method == 'pinShortcut');
        final args = (pin.arguments as Map).cast<String, dynamic>();
        expect(args['siteId'], 'ws-hs-a');
        expect(args['label'], 'Site A');

        // HS-012: pinning records the url so a later delete+recreate can be
        // routed by domain.
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutUrlLedger'))['ws-hs-a'] ==
              '$hostA/a.html',
          description: 'the pin to record the site url in the ledger',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'an orphaned tile with a domain match prompts, then is remembered '
    '(HS-011)',
    (tester) async {
      // The tile's own site is gone; its ledger url shares Site A's base
      // domain. The tile is still pinned, which is what keeps the ledger
      // entry alive through the startup reconcile (HS-012).
      seed(
        sites: [siteA()],
        ledger: {'ws-hs-ghost': '$hostA/gone.html'},
        pinnedTiles: {'ws-hs-ghost'},
      );
      await withApp(tester, () async {
        expect(
          siteIsMounted('ws-hs-a'),
          isFalse,
          reason: 'a plain launch activates no site',
        );

        // Declining leaves no trace, and a later tap asks again.
        await resumeApp(tester, withLaunch: 'ws-hs-ghost');
        await pumpUntil(
          tester,
          () => find.text('Open site?').evaluate().isNotEmpty,
          description: 'the domain-match confirmation',
        );
        await tapDialogButton(tester, 'Cancel');
        expect(
          siteIsMounted('ws-hs-a'),
          isFalse,
          reason: 'declining must not open the matched site',
        );
        expect(
          await prefsMap('shortcutSiteRemap'),
          isEmpty,
          reason: 'declining must not remember a rebind',
        );

        // Confirming opens the match and remembers it.
        await resumeApp(tester, withLaunch: 'ws-hs-ghost');
        await pumpUntil(
          tester,
          () => find.text('Open site?').evaluate().isNotEmpty,
          description: 'the confirmation to be offered again',
        );
        await tapDialogButton(tester, 'Open');
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-a'),
          description: 'the matched site to activate',
        );
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutSiteRemap'))['ws-hs-ghost'] == 'ws-hs-a',
          description: 'the confirmed rebind to persist',
        );

        // The remembered rebind resolves the next tap directly.
        await resumeApp(tester, withLaunch: 'ws-hs-ghost');
        await pumpFor(tester, const Duration(seconds: 3));
        expect(
          find.text('Open site?'),
          findsNothing,
          reason: 'a remembered rebind must resolve without prompting',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'an orphaned tile with no domain match offers reroute and create (HS-011)',
    (tester) async {
      seed(
        sites: [siteB()],
        ledger: {'ws-hs-ghost1': _kOffDomainUrl, 'ws-hs-ghost2': _kCreateUrl},
        pinnedTiles: {'ws-hs-ghost1', 'ws-hs-ghost2'},
      );
      await withApp(tester, () async {
        await resumeApp(tester, withLaunch: 'ws-hs-ghost1');
        await pumpUntil(
          tester,
          () => find.text('Shortcut site missing').evaluate().isNotEmpty,
          description: 'the missing-site chooser',
        );
        await tapDialogButton(tester, 'Open another');
        await pumpUntil(
          tester,
          () => find.text('Point shortcut at').evaluate().isNotEmpty,
          description: 'the site picker',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Site B'),
          ),
        );
        await pumpUntil(
          tester,
          () => siteIsMounted('ws-hs-b'),
          description: 'the rerouted site to activate',
        );
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutSiteRemap'))['ws-hs-ghost1'] ==
              'ws-hs-b',
          description: 'the reroute to be remembered',
        );

        // The create branch builds a site rooted at the ledger url and
        // binds the tile to it. The url is unreachable, so the title probe
        // times out first.
        await resumeApp(tester, withLaunch: 'ws-hs-ghost2');
        await pumpUntil(
          tester,
          () => find.text('Shortcut site missing').evaluate().isNotEmpty,
          description: 'the missing-site chooser for the second tile',
        );
        await tapDialogButton(tester, 'Create');
        await pumpUntil(
          tester,
          () => models().any((m) => m.initUrl == _kCreateUrl),
          description: 'the site created for the ledger url',
          timeout: const Duration(seconds: 60),
        );
        final created = models().firstWhere((m) => m.initUrl == _kCreateUrl);
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutSiteRemap'))['ws-hs-ghost2'] ==
              created.siteId,
          description: 'the created site to be bound to the tile',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'deleting a site pinned tiles reach prompts, and Disable kills the tiles '
    '(HS-013)',
    (tester) async {
      // Two tiles reach Site A: its own, and an orphaned tile rebound to it.
      seed(
        sites: [siteA(), siteB()],
        ledger: {'ws-hs-a': '$hostA/a.html', 'ws-hs-tile': _kOffDomainUrl},
        remap: {'ws-hs-tile': 'ws-hs-a'},
        pinnedTiles: {'ws-hs-a', 'ws-hs-tile'},
      );
      await withApp(tester, () async {
        Future<void> deleteFirstSite() async {
          await openSiteDrawer(tester);
          await tester.tap(
            find.descendant(
              of: find.byKey(const Key('site_0')),
              matching: find.byIcon(Icons.more_vert),
            ),
          );
          await pumpFor(tester, const Duration(seconds: 1));
          await tester.tap(find.text('Delete').last);
          await pumpUntil(
            tester,
            () => find.text('Delete Site').evaluate().isNotEmpty,
            description: 'the delete confirmation',
          );
          await tapDialogButton(tester, 'Delete');
        }

        await deleteFirstSite();
        await pumpUntil(
          tester,
          () => find.text('Home screen shortcut').evaluate().isNotEmpty,
          description: 'the HS-013 fate prompt',
        );
        expect(find.text('Keep'), findsOneWidget);
        expect(find.text('Reassign'), findsOneWidget);
        await tapDialogButton(tester, 'Disable');

        await pumpUntil(
          tester,
          () => calls.where((c) => c.method == 'disableShortcut').length == 2,
          description: 'both reaching tiles to be disabled',
        );
        final disabled = {
          for (final c in calls.where((c) => c.method == 'disableShortcut'))
            (c.arguments as Map)['siteId'] as String,
        };
        expect(
          disabled,
          {'ws-hs-a', 'ws-hs-tile'},
          reason:
              'the deleted site\'s own tile and the tile rebound to it '
              'both reach it',
        );
        await pumpUntilAsync(
          tester,
          () async =>
              (await prefsMap('shortcutSiteRemap')).isEmpty &&
              (await prefsMap('shortcutUrlLedger')).isEmpty,
          description: 'the disabled tiles\' rebind and ledger entries to drop',
        );
        await waitForDeleteToSettle(tester);

        // Site B has no tile pointing at it: deleting it must prompt nothing.
        // The drawer closing is itself the proof — the prompt would hold the
        // deletion open until answered.
        calls.clear();
        await deleteFirstSite();
        await waitForDeleteToSettle(tester);
        expect(
          find.text('Home screen shortcut'),
          findsNothing,
          reason: 'no pinned tile reaches this site',
        );
        expect(
          models().where((m) => m.siteId == 'ws-hs-b'),
          isEmpty,
          reason: 'the site should still have been deleted',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
