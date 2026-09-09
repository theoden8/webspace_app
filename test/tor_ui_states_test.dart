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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/tor_engine.dart';
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/widgets/tor_bootstrap.dart';
import 'package:webspace/widgets/tor_status_card.dart';

final bool _writePngs = Platform.environment['WS_TOR_UI_PNG'] == '1';

/// Set once real glyphs are registered. Until then Text must not name a
/// family, or it resolves to nothing and renders blank.
bool _fontsLoaded = false;

class _Runtime implements TorRuntime {
  final _events = StreamController<TorStatus>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes) async {}

  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  void emit(TorStatus s) => _events.add(s);
}

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

  Future<void> load(String family, List<String> files) async {
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

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
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
  _Runtime installEngine() {
    final runtime = _Runtime();
    TorService.overrideEngine(
      TorEngine(runtime: runtime, sessionSecret: 'secret'),
    );
    DeveloperModeService.instance.debugSet(true);
    return runtime;
  }

  tearDown(() async {
    await TorService.reset();
    DeveloperModeService.instance.debugSet(false);
  });

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));
  }

  Widget host(Widget child, Size size) => MaterialApp(
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
    WidgetTester t,
    String name,
    Widget child,
    TorStatus state,
    void Function() expectations, {
    Size size = const Size(430, 300),
  }) async {
    final runtime = installEngine();
    // Hold a refcount: the engine drops non-stopped statuses when nothing
    // holds it (the resurrection guard), so without this the emit below is
    // silently discarded and every assertion reads the wrong state.
    await TorService.instance.maybeStart('ui-test');
    await t.pumpWidget(host(child, size));
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

  group('status card', () {
    testWidgets('connected shows the live SOCKS endpoint', (t) async {
      await withState(
        t,
        'card_connected',
        const TorStatusCard(),
        const TorUp('127.0.0.1', 41337),
        () {
          expect(find.text('Connected'), findsOneWidget);
          expect(find.text('SOCKS5 on 127.0.0.1:41337'), findsOneWidget);
          expect(find.text('Rebuild circuits'), findsOneWidget);
        },
      );
    });

    testWidgets('bootstrapping shows percent and phase', (t) async {
      await withState(
        t,
        'card_bootstrapping',
        const TorStatusCard(),
        const TorBootstrapping(45,
            tag: 'loading_descriptors', summary: 'Loading relay descriptors'),
        () {
          expect(find.text('Connecting… 45%'), findsOneWidget);
          expect(find.text('Phase: Loading relay descriptors'), findsOneWidget);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, closeTo(0.45, 1e-6));
        },
      );
    });

    testWidgets('starting shows an indeterminate bar', (t) async {
      await withState(
        t,
        'card_starting',
        const TorStatusCard(),
        const TorStarting(),
        () {
          expect(find.text('Starting'), findsOneWidget);
          final bar = t.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator));
          expect(bar.value, isNull);
        },
      );
    });

    testWidgets('the card is hidden when Tor is unavailable', (t) async {
      installEngine();
      DeveloperModeService.instance.debugSet(false);
      await t.pumpWidget(host(const TorStatusCard(), const Size(430, 300)));
      await settle(t);
      expect(find.text('Tor'), findsNothing,
          reason: 'gated with the rest of Tor on developer mode');
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
        'bridges',
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
          'card_fail_$name',
          const TorStatusCard(),
          status,
          () {
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
        'interstitial_bootstrapping',
        const TorBootstrapPlaceholder(),
        const TorBootstrapping(45,
            tag: 'loading_descriptors', summary: 'Loading relay descriptors'),
        () {
          expect(find.text('Connecting… 45%'), findsOneWidget);
          expect(find.text('Phase: Loading relay descriptors'), findsOneWidget);
        },
        size: const Size(430, 430),
      );
    });

    testWidgets('a blocked network is named, with Retry', (t) async {
      await withState(
        t,
        'interstitial_censored',
        const TorBootstrapPlaceholder(),
        _errored('bootstrap stalled',
            reason: 'CONNECTREFUSED', tag: 'conn_dir', pct: 10),
        () {
          expect(find.text('Tor appears to be blocked'), findsOneWidget);
          expect(find.textContaining('bridges'), findsOneWidget);
          expect(find.text('Retry'), findsOneWidget);
        },
        size: const Size(430, 430),
      );
    });

    testWidgets('clock skew names the clock, not the network', (t) async {
      await withState(
        t,
        'interstitial_clock_skew',
        const TorBootstrapPlaceholder(),
        _errored('Clock skew of 3600 seconds detected; '
            'tor will not build circuits.'),
        () {
          expect(find.text('The device clock is wrong'), findsOneWidget);
          expect(find.textContaining('Correct the date and time'),
              findsOneWidget);
        },
        size: const Size(430, 430),
      );
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
