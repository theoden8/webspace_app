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

  group('warm-start ordering (BUG-001 Attempt 8 / PAUSE-020)', () {
    // Code-layer mirror of formal/warmstart.tla. The warm-start white screen is
    // an ORDERING defect: on Android the SurfaceView is destroyed on background
    // and re-created on foreground, and that reattach is asynchronous; it can
    // land AFTER _onResumed's one-shot tail nudge has already drained, leaving a
    // blank surface with no tick left to repaint it. Modeled here as: attach()
    // sets `owed`; a nudge tick clears it; a late attach() with no subsequent
    // nudge stays owed. Fix (Attempt 8): the attach signal (didChangeMetrics
    // within the post-resume window) fires another nudge.

    void drain(SurfaceRepaintEngine e) {
      RepaintTick t;
      do {
        t = e.tick();
      } while (!t.done);
    }

    test('reproduce: a reattach after the resume nudge drains is left owed', () {
      final e = SurfaceRepaintEngine();
      // _onResumed: the resume path (re)attaches and fires its single tail nudge.
      e.attach();
      e.request();
      drain(e);
      expect(e.owed, isFalse, reason: 'the resume nudge repainted the surface it saw');

      // Warm start: the SurfaceView re-attaches blank AFTER the nudge drained,
      // with no further trigger, the pre-Attempt-8 behavior.
      e.attach();
      expect(e.owed, isTrue,
          reason: 'BUG-001: a late reattach with no re-nudge stays blank-white');
    });

    test('fix: an attach-signal re-nudge repaints the late reattach', () {
      final e = SurfaceRepaintEngine();
      e.attach();
      e.request();
      drain(e);

      e.attach(); // late warm-start reattach
      // Attempt 8: didChangeMetrics inside the post-resume window re-nudges.
      e.request();
      drain(e);
      expect(e.owed, isFalse, reason: 'the attach-triggered re-nudge repainted it');
    });

    test('timing-faithful: late reattach at 800ms is caught only with the metrics re-nudge',
        () {
      // Host harness mirroring main.dart: _onResumed fires one nudge at resume;
      // didChangeMetrics re-fires the nudge while the post-resume window is open.
      // The resume nudge (6 ticks * 100ms = ~600ms) has drained by 800ms, when
      // the SurfaceView actually re-attaches on this device.
      for (final withMetricsRenudge in [false, true]) {
        fakeAsync((async) {
          final e = SurfaceRepaintEngine();
          void nudge() {
            if (!e.request()) return;
            void tick() {
              final t = e.tick();
              if (t.done) return;
              Future.delayed(const Duration(milliseconds: 100), tick);
            }

            tick();
          }

          // resume: tail nudge fires now.
          nudge();
          // warm-start SurfaceView reattaches blank at 800ms (after the nudge drained).
          Future.delayed(const Duration(milliseconds: 800), () {
            e.attach();
            if (withMetricsRenudge) nudge(); // didChangeMetrics within the window
          });
          async.elapse(const Duration(seconds: 3));

          expect(e.owed, withMetricsRenudge ? isFalse : isTrue,
              reason: withMetricsRenudge
                  ? 'metrics re-nudge repainted the late reattach'
                  : 'reproduction: late reattach left blank without the re-nudge');
        });
      }
    });
  });
}
