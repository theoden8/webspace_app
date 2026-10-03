import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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

  test('work deferred while busy runs once the holder lets go', () {
    var runs = 0;
    gate.busy = true;
    gate.deferUntilIdle(() => runs++);
    expect(gate.hasDeferred, isTrue);
    drain();
    expect(runs, 0, reason: 'nothing runs while the gate is held');
    gate.busy = false;
    expect(gate.hasDeferred, isFalse);
    expect(runs, 0, reason: 'never inside the releasing handler\'s finally');
    drain();
    expect(runs, 1);
  });

  test('many requests while busy run as one, the latest', () {
    final ran = <int>[];
    gate.busy = true;
    for (var i = 0; i < 5; i++) {
      gate.deferUntilIdle(() => ran.add(i));
    }
    gate.busy = false;
    drain();
    expect(ran, [4]);
  });

  test('a release with nothing waiting schedules nothing', () {
    gate.busy = true;
    gate.busy = false;
    expect(scheduled, isEmpty);
  });

  test('deferred work runs once, not again on the next release', () {
    var runs = 0;
    gate.busy = true;
    gate.deferUntilIdle(() => runs++);
    gate.busy = false;
    drain();
    gate.busy = true;
    gate.busy = false;
    drain();
    expect(runs, 1);
  });

  test('deferred work that finds the gate held again waits again', () {
    // The deferred reconcile re-checks the gate itself: a tab handler that
    // took it between the release and the microtask makes it defer anew.
    final log = <String>[];
    void reconcile() {
      if (gate.busy) {
        log.add('deferred');
        gate.deferUntilIdle(reconcile);
        return;
      }
      gate.busy = true;
      log.add('ran');
      gate.busy = false;
    }

    gate.busy = true;
    reconcile();
    gate.busy = false;
    gate.busy = true; // another handler gets in before the microtask
    drain();
    expect(log, ['deferred', 'deferred']);
    gate.busy = false;
    drain();
    expect(log, ['deferred', 'deferred', 'ran']);
    expect(gate.hasDeferred, isFalse);
  });

  test('with microtasks, the deferred work runs after the handler returns',
      () async {
    final real = TabHandlingGate(scheduleMicrotask);
    final log = <String>[];
    Future<void> handler() async {
      real.busy = true;
      try {
        await Future<void>.delayed(Duration.zero);
        real.deferUntilIdle(() => log.add('reconcile'));
        log.add('handler body');
      } finally {
        real.busy = false;
        log.add('handler released');
      }
    }

    await handler();
    expect(log, ['handler body', 'handler released']);
    await Future<void>.delayed(Duration.zero);
    expect(log, ['handler body', 'handler released', 'reconcile']);
  });
}
