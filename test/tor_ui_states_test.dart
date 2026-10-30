// Every Tor UI state, asserted and (optionally) photographed.
//
// Two jobs, deliberately separated:
//
//   * As a test it asserts what each state actually *says*. Nothing in CI
//     can run the Tor runtime — `TorService.isAvailable` is false on every
//     CI platform — so without this the card and the interstitial are never
//     exercised at all, and a failure kind that lost its remedy would ship
//     unnoticed.
//   * With `WS_TOR_UI_PNG=1` it also writes a PNG per state under
//     `build/tor_ui/` for visual review. That is a tool, not an assertion:
//     the images are derivatives (regenerable by one command) so they are
//     not committed, and pixel comparison across machines is a portability
//     problem this file deliberately does not take on.
//
// Driven through a fake TorRuntime rather than by handing the widgets canned
// state, so what is asserted is what the real status stream produces.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/screens/tor_status.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_control.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show torProxyResolver;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/external_tor_control_tiles.dart';
import 'package:webspace/widgets/external_tor_tiles.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';
import 'package:webspace/widgets/tor_status_card.dart';
import 'helpers/fake_tor_control.dart';
import 'helpers/fake_tor_runtime.dart';

final bool _writePngs = Platform.environment['WS_TOR_UI_PNG'] == '1';

/// Set once real glyphs are registered. Until then Text must not name a
/// family, or it resolves to nothing and renders blank.
bool _fontsLoaded = false;

/// Load real glyphs so a written PNG is readable.
///
/// flutter_test's default font draws every glyph as a filled box, which is
/// fine for layout assertions and useless for review. Roboto and the icon
/// font ship inside the SDK the test is already running from, so they are
/// located relative to the running Dart rather than by an absolute path
/// that would only hold on one machine.
Future<void> _loadRealFonts() async {
  // Walk up from whatever binary is running (`flutter_tester`, several
  // directories below `bin/cache`) looking for the font directory, rather
  // than assuming a fixed depth: guessing the layout is how this silently
  // loaded nothing and wrote a page of boxes the first time.
  Directory? fonts;
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}/artifacts/material_fonts');
    if (candidate.existsSync()) {
      fonts = candidate;
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  if (fonts == null) {
    // Loud, but only when the images are the point: a PNG full of boxes
    // looks like a broken UI rather than a missing font, and that misread
    // costs more than a failed test.
    if (_writePngs) {
      throw StateError(
        'material_fonts not found from ${Platform.resolvedExecutable}; '
        'PNG output would be unreadable boxes.',
      );
    }
    return;
  }
  final dirPath = fonts.path;

  Future<void> load(String family, {required List<String> files}) async {
    final loader = FontLoader(family);
    var any = false;
    for (final f in files) {
      final file = File('$dirPath/$f');
      if (!file.existsSync()) continue;
      loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      any = true;
    }
    if (any) await loader.load();
  }

  await load('Roboto', files: ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', files: ['MaterialIcons-Regular.otf']);
  _fontsLoaded = true;
}

void main() {
  // Always attempt the load, not only in PNG mode: the assertions read
  // through find.text either way, and keeping one code path means the mode
  // that produces the images is the mode that is exercised.
  setUpAll(_loadRealFonts);

  // Built inside the test body, never in setUp: TorEngine subscribes to
  // runtime.events in its constructor, and a stream delivers in the zone
  // that called listen. Constructed in setUp (the real zone) those
  // deliveries land on a microtask queue tester.pump never drains, and
  // every emit below would silently never arrive.
  FakeTorRuntime installEngine() {
    final runtime = FakeTorRuntime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
    DeveloperModeService.instance.debugSet(on: true);
    return runtime;
  }

  tearDown(() async {
    await TorService.reset();
    DeveloperModeService.instance.debugSet(on: false);
  });

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
  }

  Widget host(Widget child, {required Size size}) => MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF3F51B5),
          useMaterial3: true,
          // flutter_test's default font draws every glyph as a filled box.
          // Naming the family that _loadRealFonts registered is what makes
          // the written PNGs readable; left unset when the load failed, so
          // the run degrades to boxes rather than to blank text.
          fontFamily: _fontsLoaded ? 'Roboto' : null,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: size,
              child: Material(color: Colors.transparent, child: child),
            ),
          ),
        ),
      );

  /// Park the runtime in [state], render [child], run [expectations], and
  /// optionally photograph it.
  Future<void> withState(
    WidgetTester t, {
    required String name,
    required Widget child,
    required TorStatus state,
    required void Function() expectations,
    Size size = const Size(430, 300),
  }) async {
    // The interstitial renders the last few Tor log lines, and LogService
    // is process-wide: without this, one case's tail carries the previous
    // case's failure and the assertions read someone else's state.
    LogService.instance.resetForTest();
    final runtime = installEngine();
    // Hold a refcount: the engine drops non-stopped statuses when nothing
    // holds it (the resurrection guard), so without this the emit below is
    // silently discarded and every assertion reads the wrong state.
    await TorService.instance.maybeStart(TorSiteHolder(SiteId('ui-test')));
    await t.pumpWidget(host(child, size: size));
    await settle(t);

    runtime.emit(state);
    await settle(t);

    expectations();

    if (_writePngs) {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../build/tor_ui/$name.png'),
      );
    }

    await t.pumpWidget(const SizedBox.shrink());
    await settle(t);
    // Drain acquire's 90s bootstrap timeout and release's 60s idle debounce;
    // flutter_test fails a test that ends with a pending Timer.
    await t.pump(const Duration(seconds: 91));
  }

  /// A phone-sized window [height] tall, so a whole screen fits the PNG.
  void window(WidgetTester t, {required double height}) {
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = Size(430 * 2, height * 2);
    addTearDown(t.view.reset);
  }

  Future<void> shoot(WidgetTester t, {required String name}) async {
    if (_writePngs) {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../build/tor_ui/$name.png'));
    }
    await t.pumpWidget(const SizedBox.shrink());
    await settle(t);
    await t.pump(const Duration(seconds: 91));
  }

  group('status card', () {
    testWidgets('connected shows the live SOCKS endpoint', (t) async {
      await withState(
        t,
        name: 'card_connected',
        child: const TorStatusCard(),
        state: const TorUp('127.0.0.1', port: 41337),
        expectations: () {
          expect(find.text('Connected'), findsOneWidget);
          expect(find.text('SOCKS5 on 127.0.0.1:41337'), findsOneWidget);
          expect(find.text('Rebuild circuits'), findsOneWidget);
        },
      );
    });

    testWidgets('bootstrapping shows percent and phase', (t) async {
      await withState(
        t,
        name: 'card_bootstrapping',
        child: const TorStatusCard(),
        state: const TorBootstrapping(45,
            tag: 'loading_descriptors', summary: 'Loading relay descriptors'),
        expectations: () {
          expect(find.text('Connecting… 45%'), findsOneWidget);
          expect(find.text('Phase: Loading relay descriptors'), findsOneWidget);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, closeTo(0.45, 1e-6));
        },
      );
    });

    testWidgets('a reopen after the app was away says reconnecting, not 100%',
        (t) async {
      await withState(
        t,
        name: 'card_reconnecting',
        child: const TorStatusCard(),
        state: const TorBootstrapping(100, tag: kTorReopenTag),
        expectations: () {
          expect(find.text('Reconnecting…'), findsOneWidget);
          expect(find.textContaining('in the background'), findsOneWidget);
          expect(find.textContaining('100%'), findsNothing);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, isNull, reason: 'no percentage to show');
        },
      );
    });

    testWidgets('starting shows an indeterminate bar', (t) async {
      await withState(
        t,
        name: 'card_starting',
        child: const TorStatusCard(),
        state: const TorStarting(),
        expectations: () {
          expect(find.text('Starting'), findsOneWidget);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, isNull);
        },
      );
    });

    testWidgets('the card is hidden while nothing uses Tor', (t) async {
      installEngine();
      await t
          .pumpWidget(host(const TorStatusCard(), size: const Size(430, 300)));
      await settle(t);
      expect(TorService.instance.status, isA<TorStopped>());
      expect(find.text('Tor'), findsNothing,
          reason: 'a stopped runtime has nothing to act on (TOR-004)');
      expect(find.text('Not running'), findsNothing);
    });

    testWidgets('the card is hidden where there is no runtime', (t) async {
      TorService.overrideEngine(
        TorEngine(runtime: FakeTorRuntime(isAvailable: false), sessionSecret: 's'),
      );
      await t
          .pumpWidget(host(const TorStatusCard(), size: const Size(430, 300)));
      await settle(t);
      expect(find.text('Tor'), findsNothing);
    });
  });

  // The point of TOR-015 is that these do not look alike. One case per kind,
  // each asserting its own heading and its own remedy — a kind that fell
  // through to another kind's copy fails here.
  group('failure kinds are distinct', () {
    final cases = <String, (TorStatus, String, String)>{
      'censored': (
        _errored('bootstrap stalled',
            reason: 'CONNECTREFUSED', tag: 'conn_dir', pct: 10),
        'Tor appears to be blocked',
        'Bridges route around',
      ),
      'clock_skew': (
        _errored('Clock skew of 3600 seconds detected; '
            'tor will not build circuits.'),
        'The device clock is wrong',
        'Correct the date and time',
      ),
      'offline': (
        _errored('bootstrap stalled', reason: 'NOROUTE', pct: 5),
        'No network',
        "Check the device's connection",
      ),
      'exit_policy': (
        _errored('Could not apply the exit-country pin: no usable exit',
            pin: true),
        'No usable exit in that country',
        'Pick another country',
      ),
      'exit_country_data': (
        _errored('Could not download the GeoIP table an exit-country pin '
            'needs, so the pin was not applied.',
            pin: true),
        'Country list unavailable',
        'set the exit country back to any country',
      ),
      'control_channel': (
        _errored('Tor control authentication failed: bad cookie'),
        'Could not talk to Tor',
        'defect in the app',
      ),
      'timeout': (
        _errored('Tor did not finish bootstrapping in time.',
            pct: 95, tag: 'circuit_create', timedOut: true),
        'Tor took too long',
        'trying again often works',
      ),
      'runtime': (
        _errored('the tor thread exited unexpectedly'),
        'Tor stopped unexpectedly',
        'does not recognise',
      ),
    };

    cases.forEach((name, c) {
      final (status, title, remedyFragment) = c;
      testWidgets('$name states its own cause and remedy', (t) async {
        await withState(
          t,
          name: 'card_fail_$name',
          child: const TorStatusCard(),
          state: status,
          expectations: () {
            expect(find.text(title), findsOneWidget);
            expect(
              find.textContaining(remedyFragment),
              findsOneWidget,
              reason: '$name must offer its own remedy, not a generic one',
            );
            // The raw message stays visible: the classification is a guess
            // from patterns, and this line is what exposes a wrong guess.
            expect(find.textContaining((status as TorErrored).failure.detail),
                findsOneWidget);
            expect(find.text('Retry'), findsOneWidget);
          },
          size: const Size(430, 340),
        );
      });
    });
  });

  group('interstitial', () {
    testWidgets('bootstrapping says so instead of a mute bar', (t) async {
      await withState(
        t,
        name: 'interstitial_bootstrapping',
        child: const TorBootstrapPlaceholder(),
        state: const TorBootstrapping(45,
            tag: 'loading_descriptors', summary: 'Loading relay descriptors'),
        expectations: () {
          expect(find.text('Connecting… 45%'), findsOneWidget);
          expect(find.text('Phase: Loading relay descriptors'), findsOneWidget);
        },
        size: const Size(430, 430),
      );
    });

    testWidgets('a reopen after the app was away says what the wait is for',
        (t) async {
      // BUG-013 attempt 14: what the user saw was a page loading forever.
      // The sites now wait here, and the screen says why.
      await withState(
        t,
        name: 'interstitial_reconnecting',
        child: const TorBootstrapPlaceholder(),
        state: const TorBootstrapping(100, tag: kTorReopenTag),
        expectations: () {
          expect(find.text('Reconnecting…'), findsOneWidget);
          expect(find.textContaining('has a circuit again'), findsOneWidget);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, isNull);
        },
        size: const Size(430, 430),
      );
    });

    testWidgets('a blocked network is named, with Retry', (t) async {
      await withState(
        t,
        name: 'interstitial_censored',
        child: const TorBootstrapPlaceholder(),
        state: _errored('bootstrap stalled',
            reason: 'CONNECTREFUSED', tag: 'conn_dir', pct: 10),
        expectations: () {
          expect(find.text('Tor appears to be blocked'), findsOneWidget);
          expect(find.textContaining('Bridges route around'), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);
          // As on the status card: the classification is a guess, and the
          // raw message is what exposes a wrong one. This screen is where
          // a user is left when a TOR site will not load. It appears twice
          // now, once as the failure detail and once in the live tail
          // below it, which is the point of the tail.
          expect(find.textContaining('bootstrap stalled'), findsWidgets);
          expect(
            find.textContaining('State: error'),
            findsOneWidget,
            reason: 'the interstitial shows what the runtime last said, so '
                'a user is not left guessing at a mute bar',
          );
          // The interstitial is what a user sees when a TOR site will not
          // load; naming bridges without a route to them is how the whole
          // feature was unreachable before.
          expect(find.text('Bridges'), findsOneWidget);
        },
        size: const Size(430, 430),
      );
    });

    testWidgets('a long message scrolls rather than overflowing', (t) async {
      // tor writes its own messages and the interstitial shows them
      // verbatim, so their length is not ours to bound. An overflowing
      // column shows stripes and swallows the Retry button below it.
      await withState(
        t,
        name: 'interstitial_long_detail',
        child: const TorBootstrapPlaceholder(),
        state:
            _errored('Tor exited before opening its control port: it rejected '
                'its configuration. A bridge line is the usual cause. '
                'Bootstrap stalled at 10% in conn_dir after 3 attempts.'),
        expectations: () {
          expect(find.byType(SingleChildScrollView), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);
        },
        size: const Size(320, 260),
      );
    });

    testWidgets('clock skew names the clock, not the network', (t) async {
      await withState(
        t,
        name: 'interstitial_clock_skew',
        child: const TorBootstrapPlaceholder(),
        state: _errored('Clock skew of 3600 seconds detected; '
            'tor will not build circuits.'),
        expectations: () {
          expect(find.text('The device clock is wrong'), findsOneWidget);
          expect(find.text('Bridges'), findsNothing,
              reason: 'bridges cannot fix a wrong clock');
          expect(find.textContaining('Correct the date and time'),
              findsOneWidget);
        },
        size: const Size(430, 430),
      );
    });
  });

  // TOR-022. `stopped` is a moment inside a start-up where Tor can run and
  // the end of the road where it cannot, and the interstitial used to render
  // both the same way: "Not running" over an indeterminate bar, with no
  // Retry (that lives in the errored branch) and nothing naming the one
  // thing that would fix it. A site imported from an Apple device sat there
  // forever.
  group('the interstitial where Tor cannot come up', () {
    testWidgets('developer mode off does not stop Tor coming up', (t) async {
      installEngine();
      DeveloperModeService.instance.debugSet(on: false);
      await t.pumpWidget(
          host(const TorBootstrapPlaceholder(), size: const Size(430, 430)));
      await settle(t);

      expect(find.byType(LinearProgressIndicator), findsOneWidget,
          reason: 'Tor is not behind developer mode (TOR-007), so a site '
              'waits for it rather than being told to flip a switch');
      expect(find.text('Tor is not available on this device'), findsNothing);

      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(seconds: 91));
    });

    testWidgets('no runtime on this platform points at the site proxy',
        (t) async {
      TorService.overrideEngine(
        TorEngine(runtime: FakeTorRuntime(isAvailable: false), sessionSecret: 's'),
      );
      await t.pumpWidget(
          host(const TorBootstrapPlaceholder(), size: const Size(430, 430)));
      await settle(t);

      expect(find.text('Tor is not available on this device'), findsOneWidget);
      expect(find.textContaining('iOS and macOS only'), findsOneWidget,
          reason: 'Linux without the Built-in Tor experiment reads as before');
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('TOR-027 a Linux machine with no tor says to install one',
        (t) async {
      TorService.overrideEngine(
        TorEngine(runtime: FakeTorRuntime(isAvailable: false), sessionSecret: 's'),
        builtInOffered: true,
      );
      await t.pumpWidget(
          host(const TorBootstrapPlaceholder(), size: const Size(430, 430)));
      await settle(t);

      expect(find.text('Tor is not available on this device'), findsOneWidget);
      expect(find.textContaining('install tor to use Tor here'), findsOneWidget);
      expect(find.textContaining('iOS and macOS only'), findsNothing,
          reason: 'the experiment offers it here; this machine only lacks a tor');
    });
  });

  // TOR-026: an external tor on Linux whose control port the user named.
  group('Tor screen', () {
    testWidgets('names each site with the exit country it pins', (t) async {
      final runtime = installEngine();
      await TorService.instance.syncHolders({
        TorSiteHolder(SiteId('mail')),
        TorSiteHolder(SiteId('bank')),
        TorSiteHolder(SiteId('forum')),
        const TorAppWideHolder(),
      });
      await TorService.instance.setExitCountry('{de}');
      window(t, height: 820);
      await t.pumpWidget(host(
          TorStatusScreen(sites: {
            SiteId('mail'): (name: 'Mail', exitNodes: '{de}'),
            SiteId('bank'): (name: 'Bank', exitNodes: null),
            SiteId('forum'): (name: 'Forum', exitNodes: '{nl}'),
          }),
          size: const Size(430, 820)));
      runtime.emit(const TorUp('127.0.0.1', port: 41337));
      await settle(t);

      expect(find.text('Exit country: 🇩🇪  Deutschland (DE)'), findsOneWidget);
      expect(find.text('Exit country: 🇳🇱  Nederland (NL)'), findsOneWidget,
          reason: 'a site that is not loaded keeps its own country');
      expect(find.text('Exit country: Any country'), findsOneWidget);
      expect(find.text('Exit country'), findsNothing);
      await shoot(t, name: 'tor_screen_site_exits');
    });
  });

  group('external tor control port', () {
    tearDown(() {
      AppPref.externalTor.debugValue = AppPref.externalTor.fallback;
      AppPref.externalTorControl.debugValue =
          AppPref.externalTorControl.fallback;
    });

    /// Brings Tor up through an [ExternalTorRuntime] talking to [tor], with
    /// a site holding it, as on a Linux desktop with the tor service.
    Future<void> external(WidgetTester t, {required FakeTorControl tor}) async {
      AppPref.externalTor.debugValue = true;
      AppPref.externalTorControl.debugValue = '/run/tor/control';
      final runtime = ExternalTorRuntime(
        address: () => '127.0.0.1:9050',
        identify: (_, {required port}) async => ExternalTorAnswer.tor,
        control: ExternalTorControlAccess(
          endpoint: () => AppPref.externalTorControl.value,
          password: () async => null,
          connect: (_) async => tor.connect(),
          readCookie: (_) async => null,
        ),
      );
      TorService.overrideEngine(
        TorEngine(runtime: runtime, sessionSecret: 'secret'),
        external: runtime,
      );
      await TorService.instance.syncHolders({TorSiteHolder(SiteId('mail'))});
      await settle(t);
    }

    testWidgets('the Tor screen lists how that tor differs', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await external(t,
            tor: FakeTorControl(torrc: {
              'SocksPort': ['9050 IsolateDestAddr'],
              'ExitNodes': ['{us}'],
              'SafeLogging': ['0'],
              'StrictNodes': ['0'],
              'ConfluxEnabled': ['auto'],
            }));
        window(t, height: 1100);
        await t.pumpWidget(host(
            TorStatusScreen(
                sites: {SiteId('mail'): (name: 'Mail', exitNodes: null)}),
            size: const Size(430, 1100)));
        await settle(t);

        expect(find.text('Tor control port'), findsOneWidget);
        expect(find.text('A circuit per host'), findsOneWidget);
        expect(find.text('That tor picks exits: {us}'), findsOneWidget);
        expect(find.text('That tor logs addresses'), findsOneWidget);
        expect(find.text('Exit country: 🇺🇸  United States (US)'),
            findsOneWidget,
            reason: 'a site with no pin leaves through that tor\'s own exits');
        expect(find.text('Rebuild circuits'), findsOneWidget);
        expect(find.text('Bridges'), findsNothing,
            reason: "bridges stay that tor's own");
        await shoot(t, name: 'external_control_differences');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a stock tor service matches the built-in isolation',
        (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await external(t, tor: FakeTorControl());
        window(t, height: 420);
        await t.pumpWidget(host(
            ListView(children: const [ExternalTorTiles(offersTest: true)]),
            size: const Size(430, 420)));
        await settle(t);

        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Same isolation as the built-in Tor'), findsOneWidget);
        await shoot(t, name: 'external_control_same');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a control port that wants a password says so, and offers '
        'no exit country', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await external(t,
            tor: FakeTorControl(
                methods: {TorAuthMethod.hashedPassword}, password: 'p'));
        window(t, height: 900);
        await t.pumpWidget(host(
            TorStatusScreen(
                sites: {SiteId('mail'): (name: 'Mail', exitNodes: null)}),
            size: const Size(430, 900)));
        await settle(t);

        expect(find.text('Needs a password'), findsOneWidget);
        expect(find.textContaining('Exit country'), findsNothing);
        expect(find.text('Rebuild circuits'), findsNothing);
        await shoot(t, name: 'external_control_needs_password');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the dialog takes a socket path or host:port', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        ({String endpoint, String password})? saved;
        window(t, height: 420);
        await t.pumpWidget(host(
            Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      saved = await showDialog(
                          context: context,
                          builder: (_) => const ExternalTorControlDialog(
                              endpoint: '', password: ''));
                    },
                    child: const Text('open'))),
            size: const Size(430, 420)));
        await t.tap(find.text('open'));
        await t.pump(const Duration(milliseconds: 500));

        await t.enterText(find.byType(TextField).first, 'run/tor/control');
        await t.tap(find.text('Save'));
        // One frame builds the error, the next runs its fade-in.
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        expect(find.text('Enter a socket path that starts with /, or host:port'),
            findsOneWidget);
        await shoot(t, name: 'external_control_dialog');

        await t.pumpWidget(host(
            Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      saved = await showDialog(
                          context: context,
                          builder: (_) => const ExternalTorControlDialog(
                              endpoint: '', password: ''));
                    },
                    child: const Text('open'))),
            size: const Size(430, 420)));
        await t.tap(find.text('open'));
        await settle(t);
        await t.enterText(find.byType(TextField).first, '127.0.0.1:9051');
        await t.enterText(find.byType(TextField).last, 'hunter2');
        await t.tap(find.text('Save'));
        await settle(t);
        expect(saved, (endpoint: '127.0.0.1:9051', password: 'hunter2'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('external tor connection test', () {
    tearDown(() {
      AppPref.externalTor.debugValue = AppPref.externalTor.fallback;
      torProxyResolver = null;
    });

    testWidgets('the Tor section tests the address it names (TOR-025)',
        (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final runtime = ExternalTorRuntime(
          address: () => '127.0.0.1:9050',
          identify: (_, {required port}) async => ExternalTorAnswer.unreachable,
        );
        TorService.overrideEngine(
          TorEngine(runtime: runtime, sessionSecret: 'secret'),
          external: runtime,
        );
        torProxyResolver =
            (tag) => TorService.instance.routeFor(siteId: tag.site);
        window(t, height: 520);

        await t.pumpWidget(host(
            ListView(children: const [ExternalTorTiles(offersTest: true)]),
            size: const Size(430, 520)));
        await settle(t);
        expect(find.text('Test connection'), findsNothing,
            reason: 'with the switch off Tor is not the external tor');
        await t.pumpWidget(const SizedBox.shrink());

        AppPref.externalTor.debugValue = true;
        await t.pumpWidget(host(
            ListView(children: const [ExternalTorTiles(offersTest: true)]),
            size: const Size(430, 520)));
        await settle(t);
        expect(TorService.instance.status, isA<TorStopped>(),
            reason: 'nothing uses Tor before the test');

        await t.tap(find.text('Test connection'));
        await settle(t);
        expect(find.text('Could not reach the proxy'), findsOneWidget);
        expect(find.textContaining('Nothing answers at 127.0.0.1:9050.'),
            findsOneWidget);
        expect(TorService.instance.holders, isEmpty,
            reason: 'the test lets go of the tor it held');
        await shoot(t, name: 'external_test_unreachable');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

TorStatus _errored(
  String message, {
  String? reason,
  String? tag,
  int? pct,
  bool pin = false,
  bool timedOut = false,
}) {
  return TorErrored(
    message,
    failure: classifyTorFailure(
      message,
      torReason: reason,
      torTag: tag,
      atPercent: pct,
      hadExitPin: pin,
      timedOut: timedOut || reason != null,
    ),
  );
}
