import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/launch_zoom.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'helpers/localized.dart';

const _screen = Rect.fromLTWH(0, 0, 400, 800);
const _icon = Rect.fromLTWH(40, 300, 80, 80);

final _card = find.descendant(
  of: find.byType(LaunchZoom),
  matching: find.byType(Material),
);

/// The card over a button standing in for the page under it.
Future<LaunchZoomState> _pump(
  WidgetTester tester, {
  required VoidCallback onButton,
  bool reduceMotion = false,
  List<WebViewModel> sites = const [],
}) async {
  final zoom = GlobalKey<LaunchZoomState>();
  await pumpLocalized(
    tester,
    size: _screen.size,
    home: MediaQuery(
      data: MediaQueryData(size: _screen.size, disableAnimations: reduceMotion),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ElevatedButton(
              onPressed: onButton,
              child: const Text('Page'),
            ),
          ),
          LaunchZoom(key: zoom, sites: sites),
        ],
      ),
    ),
  );
  return zoom.currentState!;
}

WebViewModel _site() =>
    WebViewModel(initUrl: 'https://alpha.example.test', name: 'Alpha');

Uint8List _png(int width) =>
    Uint8List.fromList(image.encodePng(image.Image(width: width, height: 2)));

void main() {
  testWidgets(
    'a site\'s card starts in its icon\'s colour: marked only for a look-alike '
    'or a site with no icon (WEBSPACE-014)',
    (tester) async {
      final own = WebViewModel(
        initUrl: 'https://own.example.test',
        customIconPng: _png(3),
      )..containerColor = 1;
      final twin = WebViewModel(
        initUrl: 'https://twin.example.test',
        customIconPng: _png(4),
      )..containerColor = 2;
      final twinToo = WebViewModel(
        initUrl: 'https://twin-too.example.test',
        customIconPng: _png(4),
      )..containerColor = 3;
      final file = WebViewModel(initUrl: 'file:///card-notes.html')
        ..containerColor = 4;
      FaviconUrlCache.markMissing(file.initUrl);
      final zoom = await _pump(
        tester,
        onButton: () {},
        sites: [own, twin, twinToo, file],
      );
      Future<Color?> firstFrame(WebViewModel site) async {
        final opening = zoom.open(
          site,
          from: _icon,
          to: (show: () async {}, shown: () => true),
        );
        await tester.pump();
        final color = tester.widget<Material>(_card).color;
        await tester.pumpAndSettle();
        await opening;
        return color;
      }

      final theme = Theme.of(tester.element(find.byType(LaunchZoom)));
      Color well(WebViewModel site, {required bool marked}) =>
          SiteGridTile.wellColor(
            marked
                ? containerColorOf(site, brightness: theme.brightness)
                : null,
            theme: theme,
          );
      expect(await firstFrame(own), well(own, marked: false));
      expect(await firstFrame(twin), well(twin, marked: true));
      expect(
        await firstFrame(file),
        well(file, marked: true),
        reason: 'known to have no icon from the card\'s first frame',
      );
    },
  );

  testWidgets(
    'a card out of a row\'s smaller well starts with its icon at that well\'s scale (WEBSPACE-015)',
    (tester) async {
      final zoom = await _pump(tester, onButton: () {});
      final row = Rect.fromLTWH(
        24,
        300,
        LibraryStyle.rowWell,
        LibraryStyle.rowWell,
      );
      final opening = zoom.open(
        WebViewModel(
          initUrl: 'https://row.example.test',
          customIconPng: _png(3),
        ),
        from: row,
        to: (show: () async {}, shown: () => true),
      );
      await tester.pump();
      final icon = find.descendant(of: _card, matching: find.byType(Image));
      expect(tester.getRect(_card), row);
      expect(
        tester.getRect(icon).width,
        moreOrLessEquals(
          LibraryStyle.siteIcon * LibraryStyle.rowWell / LibraryStyle.siteWell,
        ),
        reason: 'the icon fits the well it grows out of',
      );
      await tester.pump(Motion.launch);
      expect(tester.getRect(icon).width, LibraryStyle.siteIcon);
      await tester.pumpAndSettle();
      await opening;
    },
  );

  testWidgets(
    'a site grows out of its icon, opens once its card covers the screen, then the card fades (WEBSPACE-008)',
    (tester) async {
      var taps = 0;
      final zoom = await _pump(tester, onButton: () => taps++);
      var shown = 0;
      final opening = zoom.open(
        _site(),
        from: _icon,
        to: (show: () async => shown++, shown: () => shown > 0),
      );
      await tester.pump();
      expect(tester.getRect(_card), _icon, reason: 'it starts as the icon');
      await tester.pump(const Duration(milliseconds: 120));
      final growing = tester.getRect(_card);
      expect(growing.width, greaterThan(_icon.width));
      expect(growing.width, lessThan(_screen.width));
      expect(shown, 0, reason: 'the page switches only under a full card');
      await tester.tap(find.text('Page'), warnIfMissed: false);
      expect(taps, 0, reason: 'a moving card takes no input');
      await tester.pump(Motion.launch);
      expect(tester.getRect(_card), _screen);
      expect(shown, 1);
      await tester.pump(Motion.reveal ~/ 2);
      final fading = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(LaunchZoom),
          matching: find.byType(Opacity),
        ),
      );
      expect(fading.opacity, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      await opening;
      expect(_card, findsNothing);
      await tester.tap(find.text('Page'));
      expect(taps, 1);
    },
  );

  testWidgets(
    'the library returns under a full card, which then shrinks into the icon laid out there (WEBSPACE-008)',
    (tester) async {
      final zoom = await _pump(tester, onButton: () {});
      Rect? laidOut;
      var shown = 0;
      final closing = zoom.close(
        _site(),
        to: (
          show: () async {
            shown++;
            laidOut = _icon;
          },
          shown: () => shown > 0,
          into: () => laidOut,
        ),
      );
      await tester.pump();
      expect(tester.getRect(_card), _screen);
      expect(shown, 0, reason: 'the card fades in over the site first');
      await tester.pump(Motion.reveal ~/ 2);
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(LaunchZoom),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        inExclusiveRange(0, 1),
      );
      expect(tester.getRect(_card), _screen, reason: 'at full size');
      await tester.pump(Motion.reveal);
      expect(shown, 1, reason: 'covered, the library comes back under it');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final shrinking = tester.getRect(_card);
      expect(shrinking.width, lessThan(_screen.width));
      expect(shrinking.width, greaterThan(_icon.width));
      expect(
        (shrinking.center - _icon.center).distance,
        lessThan((_screen.center - _icon.center).distance),
      );
      await tester.pumpAndSettle();
      await closing;
      expect(_card, findsNothing);
    },
  );

  testWidgets(
    'with no icon to grow from, a site opens through its card fading in and out',
    (tester) async {
      final zoom = await _pump(tester, onButton: () {});
      var shown = 0;
      final opening = zoom.open(
        _site(),
        from: null,
        to: (show: () async => shown++, shown: () => shown > 0),
      );
      await tester.pump();
      await tester.pump(Motion.reveal ~/ 2);
      expect(tester.getRect(_card).center, _screen.center);
      expect(tester.getRect(_card).width, lessThan(_screen.width));
      expect(shown, 0, reason: 'the switch waits under a full card');
      await tester.pump(Motion.reveal);
      expect(tester.getRect(_card), _screen);
      expect(shown, 1);
      await tester.pumpAndSettle();
      await opening;
      expect(_card, findsNothing);
    },
  );

  testWidgets('with no icon in view to land on, the card fades where it is', (
    tester,
  ) async {
    final zoom = await _pump(tester, onButton: () {});
    final closing = zoom.close(
      _site(),
      to: (show: () async {}, shown: () => true, into: () => null),
    );
    double opacity() => tester
        .widget<Opacity>(
          find.descendant(
            of: find.byType(LaunchZoom),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;
    await tester.pump();
    await tester.pump(Motion.reveal);
    expect(opacity(), 1, reason: 'faded in');
    for (var i = 0; i < 10 && opacity() == 1; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(Motion.reveal ~/ 3);
    expect(tester.getRect(_card).center, _screen.center);
    expect(tester.getRect(_card).width, lessThan(_screen.width));
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    await closing;
    expect(_card, findsNothing);
  });

  testWidgets(
    'a switch that never shows holds the card no longer than its cap, and one that shows lets it go at once',
    (tester) async {
      final zoom = await _pump(tester, onButton: () {});
      final never = Completer<void>();
      final opening = zoom.open(
        _site(),
        from: _icon,
        to: (show: () => never.future, shown: () => false),
      );
      await tester.pump();
      await tester.pump(Motion.launch);
      await tester.pump(Motion.launchHold ~/ 2);
      expect(tester.getRect(_card), _screen, reason: 'still waiting');
      await tester.pump(Motion.launchHold);
      await tester.pumpAndSettle();
      expect(_card, findsNothing, reason: 'the cap let it go');
      never.complete();
      await opening;
      var on = false;
      final quick = zoom.open(
        _site(),
        from: _icon,
        to: (show: () async {}, shown: () => on),
      );
      await tester.pump();
      await tester.pump(Motion.launch);
      on = true;
      final frames = await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(
        frames,
        lessThan(Motion.launchHold.inMilliseconds ~/ 100),
        reason: 'on screen, it fades at once rather than at the cap',
      );
      await quick;
    },
  );

  testWidgets('reduced motion opens and returns at once, with no card', (
    tester,
  ) async {
    final zoom = await _pump(tester, onButton: () {}, reduceMotion: true);
    var shown = 0;
    final opening = zoom.open(
      _site(),
      from: _icon,
      to: (show: () async => shown++, shown: () => true),
    );
    expect(shown, 1);
    await tester.pump();
    expect(_card, findsNothing);
    await opening;
    await zoom.close(
      _site(),
      to: (show: () async => shown++, shown: () => true, into: () => _icon),
    );
    await tester.pump();
    expect(shown, 2);
    expect(_card, findsNothing);
  });

  group('a card held by its top bar (WEBSPACE-008)', () {
    const grab = Offset(200, 30);

    /// A hold at [grab] over a library that shows when [library] completes,
    /// in the order [events] records the switches.
    Future<CardHold> hold(
      WidgetTester tester, {
      required List<String> events,
      Completer<void>? library,
      bool reduceMotion = false,
    }) async {
      final zoom = await _pump(
        tester,
        onButton: () {},
        reduceMotion: reduceMotion,
      );
      var libraryShown = false;
      var siteShown = false;
      return zoom.hold(
        _site(),
        at: grab,
        to: (
          show: () async {
            events.add('library');
            await library?.future;
            libraryShown = true;
          },
          shown: () => libraryShown,
          into: () => _icon,
        ),
        back: (
          show: () async {
            events.add('site');
            siteShown = true;
          },
          shown: () => siteShown,
        ),
      )!;
    }

    /// Where the card puts the point it was lifted by.
    Offset held(Rect card) =>
        card.topLeft + grab * (card.width / _screen.width);

    testWidgets(
      'lifts by the point held, follows the finger, smaller the further down, '
      'and past a quarter of the screen lands in the site\'s icon',
      (tester) async {
        final events = <String>[];
        final card = await hold(tester, events: events);
        await tester.pumpAndSettle();
        expect(events, ['library'], reason: 'the library comes under it');
        final lifted = tester.getRect(_card);
        expect(lifted.width, lessThan(_screen.width));
        expect((held(lifted) - grab).distance, lessThan(.001));

        card.move(to: grab + const Offset(30, 400));
        await tester.pump();
        final pulled = tester.getRect(_card);
        expect(pulled.width, lessThan(lifted.width));
        expect(
          (held(pulled) - (grab + const Offset(30, 400))).distance,
          lessThan(.001),
        );

        final landing = card.letGo(velocity: Offset.zero);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        final leaving = tester.getRect(_card);
        expect(
          (leaving.topLeft - pulled.topLeft).distance +
              (leaving.bottomRight - pulled.bottomRight).distance,
          lessThan(.001),
          reason: 'it leaves from where it is',
        );
        await tester.pump(Motion.launchBack);
        expect(tester.getRect(_card), _icon);
        await tester.pumpAndSettle();
        await landing;
        expect(_card, findsNothing);
        expect(events, ['library']);
      },
    );

    testWidgets(
      'let go short of a quarter, it goes back over the screen and the site '
      'is shown once the library has been',
      (tester) async {
        final events = <String>[];
        final library = Completer<void>();
        final card = await hold(tester, events: events, library: library);
        await tester.pump();
        await tester.pump(Motion.reveal);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(Motion.settle);
        card.move(to: grab + const Offset(0, 150));
        await tester.pump();
        expect(
          tester.getRect(_card),
          _screen,
          reason: 'it lifts once the library is under it, so the site is '
              'never seen around it',
        );
        final back = card.letGo(velocity: Offset.zero);
        await tester.pump();
        await tester.pump(Motion.settle);
        expect(tester.getRect(_card), _screen);
        expect(events, ['library'], reason: 'the library is still coming');
        await tester.pump(Motion.launchHold ~/ 2);
        expect(events, ['library'], reason: 'the site waits for the library');
        expect(tester.getRect(_card), _screen);
        library.complete();
        await tester.pumpAndSettle();
        await back;
        expect(events, ['library', 'site']);
        expect(_card, findsNothing);
      },
    );

    testWidgets(
      'a library that never shows keeps the site waiting no longer than the '
      'card\'s cap',
      (tester) async {
        final events = <String>[];
        final library = Completer<void>();
        final card = await hold(tester, events: events, library: library);
        await tester.pump();
        await tester.pump(Motion.reveal);
        final back = card.letGo(velocity: Offset.zero);
        await tester.pump();
        await tester.pump(Motion.settle);
        // An animation ends on the frame after its last value, which starts
        // the wait.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(Motion.launchHold);
        expect(events, ['library', 'site']);
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        library.complete();
        await back;
      },
    );

    for (final (name, pull, velocity, closes) in [
      ('flung down from near the top, it closes', 50.0, 1000.0, true),
      ('flung back up from far down, it goes back', 400.0, -1000.0, false),
    ]) {
      testWidgets(name, (tester) async {
        final events = <String>[];
        final card = await hold(tester, events: events);
        await tester.pumpAndSettle();
        card.move(to: grab + Offset(0, pull));
        await tester.pump();
        final letGo = card.letGo(velocity: Offset(0, velocity));
        await tester.pumpAndSettle();
        await letGo;
        expect(events, closes ? ['library'] : ['library', 'site']);
      });
    }

    testWidgets(
      'with reduced motion nothing lifts, and only a let-go that closes goes '
      'back to the library',
      (tester) async {
        for (final (pull, closes) in [(50.0, false), (400.0, true)]) {
          final events = <String>[];
          final card = await hold(tester, events: events, reduceMotion: true);
          await tester.pump();
          expect(_card, findsNothing);
          expect(events, isEmpty);
          card.move(to: grab + Offset(0, pull));
          await card.letGo(velocity: Offset.zero);
          await tester.pump();
          expect(events, closes ? ['library'] : isEmpty);
        }
      },
    );
  });
}
