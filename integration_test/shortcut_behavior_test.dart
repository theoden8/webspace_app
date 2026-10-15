// Home-shortcut behavior scenarios (openspec/specs/home-shortcut/spec.md),
// Android emulator/device only.
//
// The resolution rules themselves (StartupRestoreEngine.resolveLaunch, the
// ledger reconcile, the effective-pinned widening) are unit-tested in
// test/startup_restore_engine_test.dart. What no headless test reaches is the
// *wiring* in lib/screens/webspace_page.dart: which prompt a resolution raises, what the user's
// answer persists, whether the menu item is offered, and what the delete flow
// does with the launcher tiles that still point at the site. That is what this
// suite drives, through the real widget tree.
//
// Scenario map (requirement -> test):
//   HS-002 / HS-006  cold launch selects the site and opens it where it was
//                    left, tabs on or off; with Always open Home, at initUrl
//   HS-005 / HS-004  "Home Shortcut" hidden while a tile opens the site, shown
//                    for a site none opens, hidden for a site a tile pinned
//                    by an earlier version was rebound to
//   HS-001 / HS-012  tapping the item pins a tile with a fresh shortcut id
//                    (HS-017) and records the site's url in the ledger
//   HS-015           a refused pin says so; each pin carries a fresh id
//   HS-011           orphaned tile with a domain match: cancel leaves no trace,
//                    confirm opens and rewrites the tile, the next tap is silent
//   HS-011           orphaned tile with no match: reroute to an existing site,
//                    or create a new one for the ledger url; either rewrites
//                    the tile
//   HS-017           App Settings lists the tiles; a tap rewrites one to open
//                    another site, Disable greys one out after asking
//   HS-013           deleting a site reachable by pinned tiles prompts
//                    Keep/Reassign/Disable; Disable disables every reaching
//                    tile and drops its ledger + rebind entries; deleting an
//                    unreachable site prompts nothing
//
// The platform channel is mocked (a real launcher pin dialog is not drivable
// from in-process). The mock launcher holds each tile's id and the site its
// intent names, rewrites that on `updateShortcuts` as the launcher does, and
// drains `getLaunchSiteId` on read exactly like MainActivity's
// `intent.removeExtra`, so a re-poll on the next resume sees nothing. Pages come from an in-process loopback server so a site activation
// settles without network. The genuinely out-of-process half — a launcher tap
// delivering a real intent to a running activity — lives in the adb tier
// (scripts/run_android_lifecycle_tests.sh, INTEG-013).

import 'dart:async';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/screens/webspace_page.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'fixture_server.dart';
import 'helpers/ui.dart';

const _kShortcutChannel = MethodChannel(
  'org.codeberg.theoden8.webspace/shortcuts',
);

// Unreachable RFC 5737 test addresses: used only as ledger urls, so their base
// domain differs from the loopback sites and no connection is ever needed.
const _kOffDomainUrl = 'http://192.0.2.9/gone.html';
const _kCreateUrl = 'http://192.0.2.10/fresh.html';

/// A launcher tap: the tile tapped and the site its intent names.
typedef _Launch = ({String tile, String site});

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

  // Mock launcher state. `pendingLaunch` is the intent the next
  // `getLaunchSiteId` reads: the tapped tile and the site it names. Reading it
  // clears it, mirroring the native consume-on-read.
  _Launch? pendingLaunch;
  // The enabled pinned tiles: shortcut id -> the site its intent names.
  var pinned = <String, String>{};
  // Whether requestPinShortcut opens its dialog or throws.
  var pinFails = false;
  final calls = <MethodCall>[];

  setUpAll(() async {
    isDemoMode = true;

    // anyIPv4 so both loopback names below reach the same server.
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(server!, onEvent: (request) {
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
      unawaited(response.close());
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
              return launch == null
                  ? null
                  : {'siteId': launch.site, 'shortcutId': launch.tile};
            case 'getPinnedShortcuts':
              return [
                for (final MapEntry(:key, :value) in pinned.entries)
                  {'shortcutId': key, 'siteId': value},
              ];
            case 'pinShortcut':
              if (pinFails) throw PlatformException(code: 'ERROR');
              final args = call.arguments as Map;
              pinned[args['shortcutId'] as String] = args['siteId'] as String;
              return true;
            case 'updateShortcuts':
              for (final tile in (call.arguments as Map)['tiles'] as List) {
                final id = (tile as Map)['shortcutId'] as String;
                if (pinned.containsKey(id)) {
                  pinned[id] = tile['siteId'] as String;
                }
              }
              return true;
            case 'disableShortcut':
              pinned.remove((call.arguments as Map)['shortcutId'] as String);
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

  WebViewModel siteA({
    String? currentUrl,
    bool tabsEnabled = true,
    List<SiteTab>? tabs,
    TabId? activeTabId,
    bool alwaysOpenHome = false,
  }) =>
      WebViewModel(
        siteId: SiteId('ws-hs-a'),
        initUrl: '$hostA/a.html',
        currentUrl: currentUrl,
        name: 'Site A',
        tabsEnabled: tabsEnabled,
        tabs: tabs,
        activeTabId: activeTabId,
        alwaysOpenHome: alwaysOpenHome,
      );
  WebViewModel siteB() =>
      WebViewModel(siteId: SiteId('ws-hs-b'), initUrl: '$hostB/b.html', name: 'Site B');

  /// Seed the app's persisted state plus the mock launcher's pin set. Called
  /// before every `app.main()`; `setMockInitialValues` nullifies the
  /// SharedPreferences singleton, so each run starts from exactly this state.
  void seed({
    required List<WebViewModel> sites,
    Map<String, String> ledger = const {},
    Map<String, String> remap = const {},
    Map<String, String> pinnedTiles = const {},
    _Launch? launch,
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
    pinFails = false;
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

  Future<void> pumpUntilAsync(
    WidgetTester tester, {
    required Future<bool> Function() predicate,
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
    WidgetTester tester, {
    required bool Function() predicate,
    required String description,
    Duration timeout = const Duration(seconds: 45),
  }) => pumpUntilAsync(
    tester,
    predicate: () async => predicate(),
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
    WidgetTester tester, {
    required Future<void> Function() body,
  }) async {
    app.main();
    // Settles the home screen (no webview is mounted until a site activates,
    // and a shortcut cold launch mounts one — hence the slice-pump fallback).
    await pumpFor(tester, total: const Duration(seconds: 5));
    try {
      await body();
      // Let anything the last action left in flight drain before the tree goes
      // away: an app handler that resumes after its widget is gone throws on
      // the first `context` it touches (observed as `Navigator.pop` inside
      // `SiteEditingController.deleteSite` failing its null check). Tests that can name their own
      // completion signal should still wait on it; this is the backstop.
      await pumpFor(tester, total: const Duration(seconds: 2));
    } finally {
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (_) {};
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpFor(tester, total: const Duration(milliseconds: 500));
      FlutterError.onError = previousOnError;
      tester.takeException();
    }
  }

  List<WebViewModel> models() => debugWebViewModels ?? const [];

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
  Future<void> resumeApp(WidgetTester tester, {_Launch? withLaunch}) async {
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
    final button = find.byType(PopupMenuButton<SiteMenuAction>);
    expect(
      button,
      findsWidgets,
      reason: 'the site view should expose an overflow menu',
    );
    await tester.tap(button.last);
    await pumpFor(tester, total: const Duration(seconds: 1));
    expect(
      find.text('Settings'),
      findsWidgets,
      reason: 'the overflow menu should be open',
    );
  }

  /// A tap on the pinned [tile], carrying the site its intent names now.
  _Launch tapOn(String tile) => (tile: tile, site: pinned[tile]!);

  bool drawerIsOpen() => find.byType(Drawer).evaluate().isNotEmpty;

  Future<void> openSiteDrawer(WidgetTester tester) async {
    if (drawerIsOpen()) return;
    // Tapping the already-selected webspace tile opens the drawer (the
    // same-id branch of WebspacesController.select).
    await tester.tap(find.byKey(const ValueKey(WebspaceId.all)));
    await pumpFor(tester, total: const Duration(seconds: 2));
    expect(
      find.byType(Drawer),
      findsOneWidget,
      reason: 'the site drawer should open',
    );
  }

  /// Wait out a deletion: `SiteEditingController.deleteSite` closes the drawer as its very last
  /// statement, so a closed drawer is the signal that its whole async tail
  /// (storage sweeps, cache deletes, the HS-013 prompt) has drained. Without
  /// this the test can finish while the tail is still running, and tearing the
  /// tree down under it throws from that final `Navigator.pop`.
  Future<void> waitForDeleteToSettle(WidgetTester tester) => pumpUntil(
    tester,
    predicate: () => !drawerIsOpen(),
    description: 'the deletion to finish and close the drawer',
    timeout: const Duration(seconds: 60),
  );

Future<void> tapDialogButton(WidgetTester tester,
    {required String label}) async {
  final button = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.text(label),
  );
  if (button.evaluate().isEmpty) dumpDiagnostics('no "$label" in the dialog');
  expect(button, findsOneWidget, reason: 'dialog should offer "$label"');
  await tester.tap(button);
  await pumpFor(tester, total: const Duration(seconds: 1));
}

  // The shortcut paths in lib/screens/webspace_page.dart are Platform.isAndroid-gated; the
  // desktop integration loops skip this file by basename as well.
  final skipOffAndroid = !Platform.isAndroid;

  for (final tabsOn in [false, true]) {
    testWidgets(
      'cold launch opens the pinned site where it was left, tabs '
      '${tabsOn ? 'on' : 'off'} (HS-002 / HS-006)',
      (tester) async {
        seed(
          sites: [
            siteA(currentUrl: '$hostA/deep.html', tabsEnabled: tabsOn),
            siteB(),
          ],
          pinnedTiles: {'tile_a': 'ws-hs-a'},
          launch: (tile: 'tile_a', site: 'ws-hs-a'),
        );
        await withApp(tester, body: () async {
          await pumpUntil(
            tester,
            predicate: () => siteIsMounted('ws-hs-a'),
            description: 'the launched site to activate',
          );
          final launched = models().firstWhere((m) => m.siteId == 'ws-hs-a');
          expect(launched.currentUrl, '$hostA/deep.html',
              reason: 'without Always open Home a shortcut opens the site '
                  'where it was left (HS-006, TAB-014)');
          expect(
            siteIsMounted('ws-hs-b'),
            isFalse,
            reason: 'only the launched site should be activated',
          );

          // HS-012: on the initState/resume cadence the ledger records the
          // url of every pinned site that still exists, so a later deletion
          // leaves a routable trail. Asserted after a resume because the
          // initState pass races `StartupController.restore` for the loaded
          // model list.
          await resumeApp(tester);
          await pumpUntilAsync(
            tester,
            predicate: () async =>
                (await prefsMap('shortcutUrlLedger'))['ws-hs-a'] ==
                '$hostA/a.html',
            description:
                'the startup ledger reconcile to record the pinned url',
          );
        });
      },
      skip: skipOffAndroid,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  testWidgets(
    'cold launch with Always open Home lands on a tab at home (HS-006 / '
    'TAB-014)',
    (tester) async {
      seed(
        sites: [
          siteA(
            alwaysOpenHome: true,
            tabs: [
              SiteTab(id: TabId('deep'), url: '$hostA/deep.html'),
              SiteTab(id: TabId('other'), url: '$hostA/other.html'),
            ],
            activeTabId: TabId('deep'),
          ),
          siteB(),
        ],
        pinnedTiles: {'tile_a': 'ws-hs-a'},
        launch: (tile: 'tile_a', site: 'ws-hs-a'),
      );
      await withApp(tester, body: () async {
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-a'),
          description: 'the launched site to activate',
        );
        final launched = models().firstWhere((m) => m.siteId == 'ws-hs-a');
        expect(launched.currentUrl, launched.initUrl,
            reason: 'Always open Home is what sends a shortcut launch home');
        expect(launched.tabs.map((t) => t.url),
            containsAll(['$hostA/deep.html', '$hostA/other.html']),
            reason: 'the tabs it had are kept (TAB-014)');
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'the Home Shortcut item hides while a tile opens the site (HS-005)',
    (tester) async {
      seed(
        sites: [siteA(), siteB()],
        pinnedTiles: {'tile_a': 'ws-hs-a'},
        launch: (tile: 'tile_a', site: 'ws-hs-a'),
      );
      await withApp(tester, body: () async {
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-a'),
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
    'the Home Shortcut item hides for a site an earlier version rebound a '
    'tile to (HS-005)',
    (tester) async {
      // A tile pinned before shortcut ids, whose own site is gone, rebound to
      // Site B by an HS-011 prompt that kept a remap: B is already reachable
      // from the launcher.
      seed(
        sites: [siteA(), siteB()],
        remap: {'ws-hs-ghost': 'ws-hs-b'},
        pinnedTiles: {'site_ws-hs-ghost': 'ws-hs-ghost'},
        launch: (tile: 'site_ws-hs-ghost', site: 'ws-hs-ghost'),
      );
      await withApp(tester, body: () async {
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-b'),
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
    '(HS-004 / HS-001 / HS-012 / HS-017)',
    (tester) async {
      // Launched from a tile since removed from the home screen.
      seed(sites: [siteA(), siteB()], launch: (tile: 'tile_old', site: 'ws-hs-a'));
      await withApp(tester, body: () async {
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-a'),
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
          predicate: () => calls.any((c) => c.method == 'pinShortcut'),
          description: 'the pin request to reach the platform channel',
        );
        final pin = calls.lastWhere((c) => c.method == 'pinShortcut');
        final args = (pin.arguments as Map).cast<String, dynamic>();
        expect(args['siteId'], 'ws-hs-a');
        expect(args['label'], 'Site A');
        expect(args['shortcutId'], allOf(startsWith('tile_'), isNot('tile_old')),
            reason: 'a pinned tile gets an id of its own, never one derived '
                'from the site (HS-017)');

        // HS-012: pinning records the url so a later delete+recreate can be
        // routed by domain.
        await pumpUntilAsync(
          tester,
          predicate: () async =>
              (await prefsMap('shortcutUrlLedger'))['ws-hs-a'] ==
              '$hostA/a.html',
          description: 'the pin to record the site url in the ledger',
        );

        // The pin dialog backgrounds the app; back in front, the launcher
        // reports the new tile and the item hides.
        await resumeApp(tester);
        await pumpFor(tester, total: const Duration(seconds: 1));
        await openOverflowMenu(tester);
        expect(find.text('Home Shortcut'), findsNothing,
            reason: 'the new tile opens the site');
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'a refused pin says so, and each pin carries a fresh id (HS-015)',
    (tester) async {
      seed(sites: [siteA(), siteB()], launch: (tile: 'tile_old', site: 'ws-hs-a'));
      await withApp(tester, body: () async {
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-a'),
          description: 'the launched site to activate',
        );

        pinFails = true;
        await openOverflowMenu(tester);
        await tester.tap(find.text('Home Shortcut'));
        await pumpUntil(
          tester,
          predicate: () => find
              .text('Couldn\'t add a home screen shortcut for "Site A"')
              .evaluate()
              .isNotEmpty,
          description: 'the refused pin to be reported',
        );

        // A device restore leaves a disabled tile behind, which the launcher
        // leaves out of what it reports: the item is still offered, and the
        // new pin cannot meet that tile, since no two pins share an id.
        pinFails = false;
        await openOverflowMenu(tester);
        expect(find.text('Home Shortcut'), findsOneWidget);
        await tester.tap(find.text('Home Shortcut'));
        await pumpUntil(
          tester,
          predicate: () =>
              calls.where((c) => c.method == 'pinShortcut').length == 2,
          description: 'the second pin request',
        );
        final ids = {
          for (final c in calls.where((c) => c.method == 'pinShortcut'))
            (c.arguments as Map)['shortcutId'],
        };
        expect(ids, hasLength(2), reason: 'each pin mints its own id');
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'an orphaned tile with a domain match prompts, then is rewritten '
    '(HS-011 / HS-017)',
    (tester) async {
      // The site the tile names is gone; its ledger url shares Site A's base
      // domain. The tile is still pinned, which is what keeps the ledger
      // entry alive through the startup reconcile (HS-012).
      seed(
        sites: [siteA()],
        ledger: {'ws-hs-ghost': '$hostA/gone.html'},
        pinnedTiles: {'tile_ghost': 'ws-hs-ghost'},
      );
      await withApp(tester, body: () async {
        expect(
          siteIsMounted('ws-hs-a'),
          isFalse,
          reason: 'a plain launch activates no site',
        );

        // Declining leaves no trace, and a later tap asks again.
        await resumeApp(tester, withLaunch: tapOn('tile_ghost'));
        await pumpUntil(
          tester,
          predicate: () => find.text('Open site?').evaluate().isNotEmpty,
          description: 'the domain-match confirmation',
        );
        await tapDialogButton(tester, label: 'Cancel');
        expect(
          siteIsMounted('ws-hs-a'),
          isFalse,
          reason: 'declining must not open the matched site',
        );
        expect(
          pinned['tile_ghost'],
          'ws-hs-ghost',
          reason: 'declining must not rewrite the tile',
        );

        // Confirming opens the match and points the tile at it.
        await resumeApp(tester, withLaunch: tapOn('tile_ghost'));
        await pumpUntil(
          tester,
          predicate: () => find.text('Open site?').evaluate().isNotEmpty,
          description: 'the confirmation to be offered again',
        );
        await tapDialogButton(tester, label: 'Open');
        await pumpUntil(
          tester,
          predicate: () => siteIsMounted('ws-hs-a'),
          description: 'the matched site to activate',
        );
        await pumpUntil(
          tester,
          predicate: () => pinned['tile_ghost'] == 'ws-hs-a',
          description: 'the tile to be rewritten to open the match',
        );
        expect(await prefsMap('shortcutSiteRemap'), isEmpty,
            reason: 'an Android tile is rewritten, not remapped');

        // The rewritten tile opens the site directly.
        await resumeApp(tester, withLaunch: tapOn('tile_ghost'));
        await pumpFor(tester, total: const Duration(seconds: 3));
        expect(
          find.text('Open site?'),
          findsNothing,
          reason: 'a rewritten tile must resolve without prompting',
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
        pinnedTiles: {'tile_1': 'ws-hs-ghost1', 'tile_2': 'ws-hs-ghost2'},
      );
      await withApp(tester, body: () async {
        await resumeApp(tester, withLaunch: tapOn('tile_1'));
        await pumpUntil(
          tester,
          predicate: () =>
              find.text('Shortcut site missing').evaluate().isNotEmpty,
          description: 'the missing-site chooser',
        );
        await tapDialogButton(tester, label: 'Open another');
        await pumpUntil(
          tester,
          predicate: () => find.text('Point shortcut at').evaluate().isNotEmpty,
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
          predicate: () => siteIsMounted('ws-hs-b'),
          description: 'the rerouted site to activate',
        );
        await pumpUntil(
          tester,
          predicate: () => pinned['tile_1'] == 'ws-hs-b',
          description: 'the tile to be rewritten to the rerouted site',
        );

        // The create branch builds a site rooted at the ledger url and
        // points the tile at it. The url is unreachable, so the title probe
        // times out first.
        await resumeApp(tester, withLaunch: tapOn('tile_2'));
        await pumpUntil(
          tester,
          predicate: () =>
              find.text('Shortcut site missing').evaluate().isNotEmpty,
          description: 'the missing-site chooser for the second tile',
        );
        await tapDialogButton(tester, label: 'Create');
        await pumpUntil(
          tester,
          predicate: () => models().any((m) => m.initUrl == _kCreateUrl),
          description: 'the site created for the ledger url',
          timeout: const Duration(seconds: 60),
        );
        final created = models().firstWhere((m) => m.initUrl == _kCreateUrl);
        await pumpUntil(
          tester,
          predicate: () => pinned['tile_2'] == created.siteId,
          description: 'the tile to be rewritten to the created site',
        );
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'App Settings lists the tiles; a tap points one at another site and '
    'Disable greys one out (HS-017)',
    (tester) async {
      seed(
        sites: [siteA(), siteB()],
        pinnedTiles: {'tile_a': 'ws-hs-a', 'tile_ghost': 'ws-hs-ghost'},
      );
      await withApp(tester, body: () async {
        final settingsButton = find.byTooltip('App Settings');
        if (settingsButton.evaluate().isEmpty) {
          dumpDiagnostics('no App Settings button');
        }
        await tester.tap(settingsButton.first);
        await pumpFor(tester, total: const Duration(seconds: 2));
        await tester.tap(find.text('Behaviour'));
        await pumpFor(tester, total: const Duration(seconds: 2));
        final row = find.text('Home screen shortcuts');
        await tester.scrollUntilVisible(row, 100,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('2 shortcuts'), findsOneWidget);
        await tester.tap(row);
        await pumpFor(tester, total: const Duration(seconds: 2));
        expect(find.text('Site A'), findsOneWidget);
        expect(find.text('Deleted site'), findsOneWidget,
            reason: 'a tile whose site is gone is listed too');

        await tester.tap(find.text('Site A'));
        await pumpUntil(
          tester,
          predicate: () =>
              find.text('Point shortcut at').evaluate().isNotEmpty,
          description: 'the site picker',
        );
        await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Site B'),
        ));
        await pumpUntil(
          tester,
          predicate: () => pinned['tile_a'] == 'ws-hs-b',
          description: 'the tile to be rewritten to open Site B',
        );
        await pumpUntil(
          tester,
          predicate: () => find.text('Site B').evaluate().isNotEmpty,
          description: 'the list to show the tile opening Site B',
        );

        await tester.tap(find.descendant(
          of: find.ancestor(
            of: find.text('Deleted site'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(Icons.block),
        ));
        await pumpUntil(
          tester,
          predicate: () =>
              find.text('Disable this shortcut?').evaluate().isNotEmpty,
          description: 'the disable confirmation',
        );
        await tapDialogButton(tester, label: 'Disable');
        await pumpUntil(
          tester,
          predicate: () => !pinned.containsKey('tile_ghost'),
          description: 'the orphaned tile to be disabled',
        );
        await pumpUntil(
          tester,
          predicate: () => find.text('Deleted site').evaluate().isEmpty,
          description: 'the disabled tile to leave the list',
        );
        expect(pinned, {'tile_a': 'ws-hs-b'});
      });
    },
    skip: skipOffAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'deleting a site pinned tiles reach prompts, and Disable kills the tiles '
    '(HS-013)',
    (tester) async {
      // Two tiles reach Site A: one naming it, and one pinned by an earlier
      // version whose site is gone, rebound to A by a remap.
      seed(
        sites: [siteA(), siteB()],
        ledger: {'ws-hs-a': '$hostA/a.html', 'ws-hs-tile': _kOffDomainUrl},
        remap: {'ws-hs-tile': 'ws-hs-a'},
        pinnedTiles: {'tile_a': 'ws-hs-a', 'site_ws-hs-tile': 'ws-hs-tile'},
      );
      await withApp(tester, body: () async {
        Future<void> deleteFirstSite() async {
          await openSiteDrawer(tester);
          await tester.tap(
            find.descendant(
              of: find.byKey(const Key('site_0')),
              matching: find.byIcon(Icons.more_vert),
            ),
          );
          await pumpFor(tester, total: const Duration(seconds: 1));
          await tester.tap(find.text('Delete').last);
          await pumpUntil(
            tester,
            predicate: () => find.text('Delete Site').evaluate().isNotEmpty,
            description: 'the delete confirmation',
          );
          await tapDialogButton(tester, label: 'Delete');
        }

        await deleteFirstSite();
        await pumpUntil(
          tester,
          predicate: () =>
              find.text('Home screen shortcut').evaluate().isNotEmpty,
          description: 'the HS-013 fate prompt',
        );
        expect(find.text('Keep'), findsOneWidget);
        expect(find.text('Reassign'), findsOneWidget);
        await tapDialogButton(tester, label: 'Disable');

        await pumpUntil(
          tester,
          predicate: () =>
              calls.where((c) => c.method == 'disableShortcut').length == 2,
          description: 'both reaching tiles to be disabled',
        );
        final disabled = {
          for (final c in calls.where((c) => c.method == 'disableShortcut'))
            (c.arguments as Map)['shortcutId'] as String,
        };
        expect(
          disabled,
          {'tile_a', 'site_ws-hs-tile'},
          reason:
              'the deleted site\'s own tile and the tile rebound to it '
              'both reach it',
        );
        await pumpUntilAsync(
          tester,
          predicate: () async =>
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
