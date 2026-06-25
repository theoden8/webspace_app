import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/surface_repaint_engine.dart';

void main() {
  group('mustRepaint coverage contract', () {
    test('every surface-attach transition owes a repaint; appBackground does not',
        () {
      for (final t in SurfaceTransition.values) {
        final expected = t != SurfaceTransition.appBackground;
        expect(SurfaceRepaintEngine.mustRepaint(t), expected, reason: '$t');
      }
    });

    test('back and forward owe a repaint (PAUSE-018 / BUG-001)', () {
      expect(SurfaceRepaintEngine.mustRepaint(SurfaceTransition.back), isTrue);
      expect(SurfaceRepaintEngine.mustRepaint(SurfaceTransition.forward), isTrue);
    });
  });

  group('coalescing tick machine', () {
    test('first request starts the loop and drains to a settled zero inset', () {
      final e = SurfaceRepaintEngine();
      expect(e.request(), isTrue);
      expect(e.isLooping, isTrue);

      final insets = <bool>[];
      RepaintTick t;
      do {
        t = e.tick();
        if (!t.done) insets.add(t.inset);
      } while (!t.done);

      expect(insets, [true, false, true, false, true, false]);
      expect(e.inset, isFalse, reason: 'settled at zero');
      expect(e.isLooping, isFalse);
    });

    test('a concurrent request never starts a second loop', () {
      final e = SurfaceRepaintEngine();
      expect(e.request(), isTrue);
      e.tick();
      expect(e.request(), isFalse, reason: 'an existing loop absorbs it');
      expect(e.isLooping, isTrue);
    });

    test('refill mid-loop extends the budget and still settles at zero', () {
      final e = SurfaceRepaintEngine();
      e.request();
      e.tick();
      e.tick();
      e.tick(); // drained 3 of 6
      expect(e.request(), isFalse); // a coalesced second caller refills to 6

      var ticks = 0;
      RepaintTick t;
      do {
        t = e.tick();
        ticks++;
      } while (!t.done);

      expect(ticks, greaterThan(3), reason: 'budget was refilled, not exhausted');
      expect(e.inset, isFalse);
      expect(e.isLooping, isFalse);
    });

    test('abort stops the loop with no inset owed', () {
      final e = SurfaceRepaintEngine();
      e.request();
      e.tick(); // inset now true
      e.abort();
      expect(e.isLooping, isFalse);
      expect(e.inset, isFalse);
    });
  });

  group('interleaving under FakeAsync (the nudge-loop race)', () {
    // Host harness mirroring _nudgeSurfaceRepaint but Timer-based (no Flutter):
    // two nudges fired mid-loop must coalesce onto ONE loop that terminates at a
    // zero inset — the race attempts 2-3 fixed by making the loop re-entrant.
    test('two nudges 50ms apart run a single terminating loop', () {
      fakeAsync((async) {
        final e = SurfaceRepaintEngine();
        var rendered = false; // stands in for setState(_repaintNudge = ...)
        var loopsStarted = 0;

        void nudge() {
          if (!e.request()) return;
          loopsStarted++;
          void tick() {
            final t = e.tick();
            rendered = t.inset;
            if (t.done) return;
            Future.delayed(const Duration(milliseconds: 100), tick);
          }

          tick();
        }

        nudge();
        Future.delayed(const Duration(milliseconds: 50), nudge);
        async.elapse(const Duration(seconds: 3));

        expect(loopsStarted, 1, reason: 'coalesced onto a single loop');
        expect(e.isLooping, isFalse, reason: 'loop terminated');
        expect(rendered, isFalse, reason: 'settled at zero inset');
      });
    });
  });
}
