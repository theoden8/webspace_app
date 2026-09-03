import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/repaint_log_throttle.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('RepaintLogThrottle', () {
    test('the first request of a burst is always announced', () {
      final t = RepaintLogThrottle();
      expect(t.note('reload', coalesced: false, now: at(0)),
          ['trigger=reload -> nudge']);
    });

    test('a metrics burst collapses to one line plus one summary', () {
      final t = RepaintLogThrottle();
      final emitted = <String>[
        ...t.note('metrics-resume', coalesced: false, now: at(0)),
      ];
      for (var i = 1; i <= 12; i++) {
        emitted.addAll(t.note('metrics-resume', coalesced: true, now: at(i * 50)));
      }
      expect(emitted, ['trigger=metrics-resume -> nudge'],
          reason: 'the repeats stay folded until a flush');
      expect(t.hasPending, isTrue);
      expect(t.flush(), 'trigger=metrics-resume -> nudge x12 more (12 coalesced)');
      expect(t.hasPending, isFalse);
    });

    test('a different trigger flushes the burst before announcing itself', () {
      final t = RepaintLogThrottle();
      t.note('metrics-resume', coalesced: false, now: at(0));
      t.note('metrics-resume', coalesced: true, now: at(50));
      t.note('metrics-resume', coalesced: true, now: at(100));
      expect(
        t.note('reload', coalesced: false, now: at(150)),
        [
          'trigger=metrics-resume -> nudge x2 more (2 coalesced)',
          'trigger=reload -> nudge',
        ],
        reason: 'the trace must not reorder the burst after the event that ended it',
      );
    });

    test('the same trigger past the window is a new event, not a repeat', () {
      final t = RepaintLogThrottle();
      t.note('back', coalesced: false, now: at(0));
      final late = t.note('back',
          coalesced: false,
          now: at(RepaintLogThrottle.burstWindow.inMilliseconds + 1));
      expect(late, ['trigger=back -> nudge'],
          reason: 'two separate back gestures are two events');
    });

    test('flushing with nothing folded says nothing', () {
      final t = RepaintLogThrottle();
      expect(t.flush(), isNull);
      t.note('reload', coalesced: false, now: at(0));
      expect(t.flush(), isNull, reason: 'the line was already emitted');
    });

    test('a burst outliving one flush reports as successive summaries', () {
      final t = RepaintLogThrottle();
      t.note('metrics-resume', coalesced: false, now: at(0));
      t.note('metrics-resume', coalesced: true, now: at(100));
      expect(t.flush(), 'trigger=metrics-resume -> nudge x1 more (1 coalesced)');
      // The window restarted, so the next one is announced afresh rather than
      // silently folded into a burst nobody will ever see summarised.
      expect(t.note('metrics-resume', coalesced: true, now: at(200)),
          ['trigger=metrics-resume -> nudge (coalesced)']);
    });

    test('an uncoalesced burst omits the coalesced count', () {
      final t = RepaintLogThrottle();
      t.note('activate', coalesced: false, now: at(0));
      t.note('activate', coalesced: false, now: at(10));
      expect(t.flush(), 'trigger=activate -> nudge x1 more');
    });
  });
}
