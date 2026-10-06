import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/tab_handling_gate.dart';

/// The guard every tab handler holds across its awaits, and the work that
/// waits for it (UI race conditions, LIR-034).
void main() {
  late List<void Function()> scheduled;
  late TabHandlingGate gate;

  setUp(() {
    scheduled = [];
    gate = TabHandlingGate(scheduled.add);
  });

  void drain() {
    while (scheduled.isNotEmpty) {
      scheduled.removeAt(0)();
    }
  }

  /// Holds the gate until the returned completer completes.
  (Future<bool>, Completer<void>) hold(ReentryGuard guard) {
    final release = Completer<void>();
    return (guard.run(() => release.future), release);
  }

  test('a second run while the first is in flight is skipped', () async {
    final (first, release) = hold(gate);
    var secondRan = false;
    expect(await gate.run(() async => secondRan = true), isFalse);
    release.complete();
    expect(await first, isTrue);
    expect(secondRan, isFalse);
    expect(gate.busy, isFalse);
  });

  test('a body that throws still releases the gate', () async {
    await expectLater(
        gate.run(() async => throw StateError('handler failed')),
        throwsStateError);
    expect(gate.busy, isFalse);
    expect(await gate.run(() async {}), isTrue);
  });

  test('work deferred while busy runs once the holder lets go', () async {
    var runs = 0;
    final (held, release) = hold(gate);
    gate.deferUntilIdle(() => runs++);
    expect(gate.hasDeferred, isTrue);
    drain();
    expect(runs, 0, reason: 'nothing runs while the gate is held');
    release.complete();
    await held;
    expect(gate.hasDeferred, isFalse);
    expect(runs, 0, reason: 'never inside the releasing handler\'s finally');
    drain();
    expect(runs, 1);
  });

  test('many requests while busy run as one, the latest', () async {
    final ran = <int>[];
    final (held, release) = hold(gate);
    for (var i = 0; i < 5; i++) {
      gate.deferUntilIdle(() => ran.add(i));
    }
    release.complete();
    await held;
    drain();
    expect(ran, [4]);
  });

  test('a release with nothing waiting schedules nothing', () async {
    await gate.run(() async {});
    expect(scheduled, isEmpty);
  });

  test('deferred work runs once, not again on the next release', () async {
    var runs = 0;
    final (held, release) = hold(gate);
    gate.deferUntilIdle(() => runs++);
    release.complete();
    await held;
    drain();
    await gate.run(() async {});
    drain();
    expect(runs, 1);
  });

  test('deferred work that finds the gate held again waits again', () async {
    // The deferred reconcile re-checks the gate itself: a tab handler that
    // took it between the release and the microtask makes it defer anew.
    final log = <String>[];
    void reconcile() {
      if (gate.busy) {
        log.add('deferred');
        gate.deferUntilIdle(reconcile);
        return;
      }
      unawaited(gate.run(() async => log.add('ran')));
    }

    final (first, releaseFirst) = hold(gate);
    reconcile();
    releaseFirst.complete();
    await first;
    // another handler gets in before the microtask
    final (second, releaseSecond) = hold(gate);
    drain();
    expect(log, ['deferred', 'deferred']);
    releaseSecond.complete();
    await second;
    drain();
    await Future<void>.delayed(Duration.zero);
    expect(log, ['deferred', 'deferred', 'ran']);
    expect(gate.hasDeferred, isFalse);
  });

  test('with microtasks, the deferred work runs after the handler returns',
      () async {
    final real = TabHandlingGate(scheduleMicrotask);
    final log = <String>[];
    Future<void> handler() async {
      await real.run(() async {
        await Future<void>.delayed(Duration.zero);
        real.deferUntilIdle(() => log.add('reconcile'));
        log.add('handler body');
      });
      log.add('handler released');
    }

    await handler();
    expect(log, ['handler body', 'handler released']);
    await Future<void>.delayed(Duration.zero);
    expect(log, ['handler body', 'handler released', 'reconcile']);
  });

  test('idle completes on the next release, and at once when free', () async {
    final real = TabHandlingGate(scheduleMicrotask);
    await real.idle();
    final (held, release) = hold(real);
    var released = false;
    final waiting = real.idle().then((_) => released = true);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);
    release.complete();
    await held;
    await waiting;
    expect(released, isTrue);
  });

  test('runWhenIdle waiters take the gate one at a time', () async {
    final real = TabHandlingGate(scheduleMicrotask);
    final log = <String>[];
    Future<String> exclusive(String name) => real.runWhenIdle(() async {
          log.add('$name in');
          await Future<void>.delayed(Duration.zero);
          log.add('$name out');
          return name;
        });

    final (held, release) = hold(real);
    final a = exclusive('a');
    final b = exclusive('b');
    release.complete();
    await held;
    expect(await Future.wait([a, b]), ['a', 'b']);
    expect(log, ['a in', 'a out', 'b in', 'b out']);
    expect(real.busy, isFalse);
  });
}
