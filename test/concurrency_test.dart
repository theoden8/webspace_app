import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/utils/concurrency.dart';

void main() {
  group('SerialQueue', () {
    test('runs tasks one at a time in submission order', () async {
      final queue = SerialQueue('test');
      final log = <String>[];
      final gate = Completer<void>();
      final first = queue.run(() async {
        log.add('first start');
        await gate.future;
        log.add('first end');
        return 1;
      });
      final second = queue.run(() async {
        log.add('second');
        return 2;
      });
      await Future<void>.delayed(Duration.zero);
      expect(log, ['first start']);
      gate.complete();
      expect(await first, 1);
      expect(await second, 2);
      expect(log, ['first start', 'first end', 'second']);
    });

    test('a failure reaches its caller and does not poison later tasks',
        () async {
      final queue = SerialQueue('test');
      final failed = queue.run<int>(() async => throw const FormatException('x'));
      final later = queue.run(() async => 7);
      await expectLater(failed, throwsA(isA<FormatException>()));
      expect(await later, 7);
    });

    test('a synchronous throw is delivered as the task\'s error', () async {
      final queue = SerialQueue('test');
      final failed = queue.run<int>(() => throw StateError('sync'));
      await expectLater(failed, throwsStateError);
      expect(await queue.run(() async => 'next'), 'next');
    });

    test('a failure the caller ignores is not swallowed', () async {
      final queue = SerialQueue('test');
      final errors = <Object>[];
      await runZonedGuarded(() async {
        unawaited(queue.run<void>(() async => throw ArgumentError('bug')));
        await queue.run(() async {});
      }, (e, _) => errors.add(e));
      await Future<void>.delayed(Duration.zero);
      expect(errors, [isA<ArgumentError>()]);
    });
  });

  group('deadlock', () {
    test('a task that waits on its own queue is refused', () async {
      final queue = SerialQueue('self');
      await expectLater(
        queue.run(() => queue.run(() async {})),
        throwsA(isA<AssertionError>()
            .having((e) => '${e.message}', 'message', contains('behind itself'))),
      );
    });

    test('a task may put work behind itself without waiting for it', () async {
      final queue = SerialQueue('behind');
      final log = <String>[];
      await queue.run(() async {
        queue.enqueue(() async => log.add('after'));
        log.add('first');
      });
      await queue.run(() async {});
      expect(log, ['first', 'after']);
    });

    test('work a task left running holds nothing once the task ends',
        () async {
      final queue = SerialQueue('left');
      final later = Completer<void>();
      Future<void>? leftover;
      await queue.run(() async {
        leftover = () async {
          await later.future;
          await queue.run(() async {});
        }();
      });
      later.complete();
      await leftover;
    });

    test('two queues waited on in both orders are refused, though the two '
        'tasks never met', () async {
      final a = SerialQueue('orderA');
      final b = SerialQueue('orderB');
      await a.run(() => b.run(() async {}));
      await expectLater(
        b.run(() => a.run(() async {})),
        throwsA(isA<AssertionError>()
            .having((e) => '${e.message}', 'message', contains('reverse'))),
      );
    });

    test('an order reversed through a third queue is refused', () async {
      final a = SerialQueue('chainA');
      final b = SerialQueue('chainB');
      final c = SerialQueue('chainC');
      await a.run(() => b.run(() async {}));
      await b.run(() => c.run(() async {}));
      await expectLater(
        c.run(() => a.run(() async {})),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a flight that waits on itself is refused', () async {
      final flight = SingleFlight<String, int>();
      late Future<int> inner;
      await expectLater(
        flight.run('k', call: () async {
          inner = flight.run('k', call: () async => 2);
          return inner;
        }),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('SingleFlight', () {
    test('concurrent calls for one key share one call', () async {
      final flight = SingleFlight<String, int>();
      var calls = 0;
      final gate = Completer<int>();
      Future<int> call() {
        calls++;
        return gate.future;
      }

      final a = flight.run('k', call: call);
      final b = flight.run('k', call: call);
      expect(flight.isRunning('k'), isTrue);
      gate.complete(5);
      expect(await a, 5);
      expect(await b, 5);
      expect(calls, 1);
    });

    test('distinct keys do not share', () async {
      final flight = SingleFlight<String, String>();
      final results = await Future.wait([
        flight.run('a', call: () async => 'A'),
        flight.run('b', call: () async => 'B'),
      ]);
      expect(results, ['A', 'B']);
    });

    test('a settled call is forgotten before its callers resume', () async {
      final flight = SingleFlight<(), int>();
      var calls = 0;
      final value = await flight.run((), call: () async => ++calls);
      expect(flight.isRunning(()), isFalse);
      expect(value, 1);
      expect(await flight.run((), call: () async => ++calls), 2);
    });

    test('a failure reaches every sharer and the next call runs afresh',
        () async {
      final flight = SingleFlight<String, int>();
      final gate = Completer<int>();
      final a = flight.run('k', call: () => gate.future);
      final b = flight.run('k', call: () => gate.future);
      gate.completeError(const FormatException('down'));
      await expectLater(a, throwsA(isA<FormatException>()));
      await expectLater(b, throwsA(isA<FormatException>()));
      expect(await flight.run('k', call: () async => 3), 3);
    });
  });
}
