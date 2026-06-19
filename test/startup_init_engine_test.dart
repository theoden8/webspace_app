import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/startup_init_engine.dart';

void main() {
  group('StartupInitEngine.runIndependentInits', () {
    test('runs every init concurrently, not serially', () async {
      const stepDelay = Duration(milliseconds: 100);
      const stepCount = 8;

      var active = 0;
      var maxConcurrent = 0;
      final steps = <AsyncStep>[
        for (var i = 0; i < stepCount; i++)
          () async {
            active++;
            if (active > maxConcurrent) maxConcurrent = active;
            await Future<void>.delayed(stepDelay);
            active--;
          },
      ];

      final sw = Stopwatch()..start();
      await StartupInitEngine.runIndependentInits(steps);
      sw.stop();

      // Future.wait kicks every step off before any awaits, so all of them are
      // in-flight at once. A regression to sequential `await`s would cap this
      // at 1.
      expect(maxConcurrent, stepCount);
      // Wall-clock tracks the slowest step, not the sum. Generous bound (the
      // ideal is ~100ms; serial would be 800ms) keeps it non-flaky on loaded
      // CI while still failing hard if the inits re-serialize.
      expect(sw.elapsed, lessThan(stepDelay * stepCount));
    });

    test('cold-start critical path stays under the 500ms budget', () async {
      // Per-step costs modeled on the real inits: the adblock engine spin-up
      // dominates, the rest are lighter disk reads. Serial sum is ~545ms;
      // run concurrently it must land well under the 0.5s startup budget.
      final costsMs = <int>[200, 90, 60, 50, 40, 35, 40, 30];
      final steps = <AsyncStep>[
        for (final ms in costsMs)
          () => Future<void>.delayed(Duration(milliseconds: ms)),
      ];

      final sw = Stopwatch()..start();
      await StartupInitEngine.runIndependentInits(steps);
      sw.stop();

      expect(costsMs.reduce((a, b) => a + b), greaterThan(500),
          reason: 'serial sum should exceed the budget, proving the test '
              'would fail without concurrency');
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('bridgeSetup runs synchronously before any independent init', () async {
      final order = <String>[];
      var bridgeRan = false;

      await StartupInitEngine.runIndependentInits(
        <AsyncStep>[
          () async {
            order.add('init');
            await Future<void>.delayed(const Duration(milliseconds: 10));
          },
        ],
        bridgeSetup: () {
          bridgeRan = true;
          order.add('bridge');
        },
      );

      expect(bridgeRan, isTrue);
      expect(order.first, 'bridge');
    });

    test('completes only after every init finishes', () async {
      final done = <int>{};
      final steps = <AsyncStep>[
        for (var i = 0; i < 5; i++)
          () async {
            await Future<void>.delayed(Duration(milliseconds: 10 * (i + 1)));
            done.add(i);
          },
      ];

      await StartupInitEngine.runIndependentInits(steps);

      expect(done, {0, 1, 2, 3, 4});
    });
  });
}
