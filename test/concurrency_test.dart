import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/utils/concurrency.dart';

void main() {
  group('SerialQueue', () {
    test('runs tasks one at a time in submission order', () async {
      final queue = SerialQueue();
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
      final queue = SerialQueue();
      final failed = queue.run<int>(() async => throw const FormatException('x'));
      final later = queue.run(() async => 7);
      await expectLater(failed, throwsA(isA<FormatException>()));
      expect(await later, 7);
    });

    test('a synchronous throw is delivered as the task\'s error', () async {
      final queue = SerialQueue();
      final failed = queue.run<int>(() => throw StateError('sync'));
      await expectLater(failed, throwsStateError);
      expect(await queue.run(() async => 'next'), 'next');
    });

    test('a failure the caller ignores is not swallowed', () async {
      final queue = SerialQueue();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        unawaited(queue.run<void>(() async => throw ArgumentError('bug')));
        await queue.run(() async {});
      }, (e, _) => errors.add(e));
      await Future<void>.delayed(Duration.zero);
      expect(errors, [isA<ArgumentError>()]);
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

      final a = flight.run('k', call);
      final b = flight.run('k', call);
      expect(flight.isRunning('k'), isTrue);
      gate.complete(5);
      expect(await a, 5);
      expect(await b, 5);
      expect(calls, 1);
    });

    test('distinct keys do not share', () async {
      final flight = SingleFlight<String, String>();
      final results = await Future.wait([
        flight.run('a', () async => 'A'),
        flight.run('b', () async => 'B'),
      ]);
      expect(results, ['A', 'B']);
    });

    test('a settled call is forgotten before its callers resume', () async {
      final flight = SingleFlight<(), int>();
      var calls = 0;
      final value = await flight.run((), () async => ++calls);
      expect(flight.isRunning(()), isFalse);
      expect(value, 1);
      expect(await flight.run((), () async => ++calls), 2);
    });

    test('a failure reaches every sharer and the next call runs afresh',
        () async {
      final flight = SingleFlight<String, int>();
      final gate = Completer<int>();
      final a = flight.run('k', () => gate.future);
      final b = flight.run('k', () => gate.future);
      gate.completeError(const FormatException('down'));
      await expectLater(a, throwsA(isA<FormatException>()));
      await expectLater(b, throwsA(isA<FormatException>()));
      expect(await flight.run('k', () async => 3), 3);
    });
  });
}
