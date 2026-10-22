import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/launch_zoom.dart';
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
}) async {
  final zoom = GlobalKey<LaunchZoomState>();
  await pumpLocalized(
    tester,
    size: _screen.size,
    home: MediaQuery(
      data: MediaQueryData(
        size: _screen.size,
        disableAnimations: reduceMotion,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: ElevatedButton(
              onPressed: onButton,
              child: const Text('Page'),
            ),
          ),
          LaunchZoom(key: zoom),
        ],
      ),
    ),
  );
  return zoom.currentState!;
}

WebViewModel _site() =>
    WebViewModel(initUrl: 'https://alpha.example.test', name: 'Alpha');

void main() {
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
        find.descendant(of: find.byType(LaunchZoom), matching: find.byType(Opacity)),
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
      expect(tester.getRect(_card), _screen, reason: 'covers the switch');
      expect(shown, 1);
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
    await tester.pump();
    await tester.pump();
    await tester.pump(Motion.reveal ~/ 2);
    expect(tester.getRect(_card).center, _screen.center);
    expect(tester.getRect(_card).width, lessThan(_screen.width));
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
