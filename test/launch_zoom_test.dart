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
          show: () async {},
          shown: () => true,
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
    'a site grows out of its icon, opens once its card covers the screen, then the card fades (WEBSPACE-008)',
    (tester) async {
      var taps = 0;
      final zoom = await _pump(tester, onButton: () => taps++);
      var shown = 0;
      final opening = zoom.open(
        _site(),
        from: _icon,
        show: () async => shown++,
        shown: () => shown > 0,
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
        show: () async {
          shown++;
          laidOut = _icon;
        },
        shown: () => shown > 0,
        into: () => laidOut,
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
        show: () async => shown++,
        shown: () => shown > 0,
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
      show: () async {},
      shown: () => true,
      into: () => null,
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
        show: () => never.future,
        shown: () => false,
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
        show: () async {},
        shown: () => on,
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
      show: () async => shown++,
      shown: () => true,
    );
    expect(shown, 1);
    await tester.pump();
    expect(_card, findsNothing);
    await opening;
    await zoom.close(
      _site(),
      show: () async => shown++,
      shown: () => true,
      into: () => _icon,
    );
    await tester.pump();
    expect(shown, 2);
    expect(_card, findsNothing);
  });
}
