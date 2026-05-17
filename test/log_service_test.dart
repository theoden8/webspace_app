import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';

void main() {
  setUp(() {
    LogService.instance.resetForTest();
  });

  group('LogService normal entries', () {
    test('reach the persisted entries sink', () {
      LogService.instance.log('Test', 'hello');
      expect(LogService.instance.entries, hasLength(1));
      expect(LogService.instance.entries.first.message, 'hello');
    });

    test('appear in export()', () {
      LogService.instance.log('Test', 'first');
      LogService.instance.log('Test', 'second');
      final out = LogService.instance.export();
      expect(out, contains('first'));
      expect(out, contains('second'));
    });
  });

  group('LogService sensitive entries', () {
    test('stay out of the normal entries sink', () {
      LogService.instance.log(
        'Test',
        'secret-payload',
        sensitivity: LogSensitivity.sensitive,
      );
      expect(LogService.instance.entries, isEmpty);
      expect(LogService.instance.sensitiveEntries, hasLength(1));
      expect(LogService.instance.sensitiveEntries.first.message,
          'secret-payload');
    });

    test('never reach export() (memory-only contract)', () {
      LogService.instance.log(
        'Test',
        'secret-payload',
        sensitivity: LogSensitivity.sensitive,
      );
      final out = LogService.instance.export();
      expect(out, isNot(contains('secret-payload')));
    });

    test('do NOT print to the zone print stream', () {
      final captured = <String>[];
      runZoned(
        () {
          LogService.instance.log(
            'Test',
            'secret-payload',
            sensitivity: LogSensitivity.sensitive,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            captured.add(line);
          },
        ),
      );
      expect(captured.where((l) => l.contains('secret-payload')), isEmpty);
    });

    test('show up in allEntriesMerged ordered by timestamp', () async {
      LogService.instance.log('Test', 'first-normal');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      LogService.instance.log(
        'Test',
        'sensitive-mid',
        sensitivity: LogSensitivity.sensitive,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      LogService.instance.log('Test', 'last-normal');

      final merged = LogService.instance.allEntriesMerged;
      expect(merged.map((e) => e.message), [
        'first-normal',
        'sensitive-mid',
        'last-normal',
      ]);
    });

    test('are cleared on simulated process restart (resetForTest)', () {
      LogService.instance.log(
        'Test',
        'pre-restart',
        sensitivity: LogSensitivity.sensitive,
      );
      expect(LogService.instance.sensitiveEntries, hasLength(1));

      // Simulate a cold launch: the in-memory ring is wiped, the toggle
      // would reset to off (UI concern), and the singleton is reused.
      LogService.instance.resetForTest();

      expect(LogService.instance.sensitiveEntries, isEmpty);
      expect(LogService.instance.entries, isEmpty);
    });

    test('clear() wipes both rings', () {
      LogService.instance.log('Test', 'normal-1');
      LogService.instance.log(
        'Test',
        'sensitive-1',
        sensitivity: LogSensitivity.sensitive,
      );
      LogService.instance.clear();
      expect(LogService.instance.entries, isEmpty);
      expect(LogService.instance.sensitiveEntries, isEmpty);
    });

    test('respect the per-ring maxEntries cap', () {
      for (var i = 0; i < LogService.maxEntries + 50; i++) {
        LogService.instance.log(
          'Test',
          'sensitive-$i',
          sensitivity: LogSensitivity.sensitive,
        );
      }
      expect(LogService.instance.sensitiveEntries,
          hasLength(LogService.maxEntries));
      // The oldest entries should have rolled off.
      expect(
        LogService.instance.sensitiveEntries.first.message,
        'sensitive-50',
      );
    });
  });

  group('LogEntry shape', () {
    test('default sensitivity is normal', () {
      LogService.instance.log('Test', 'message');
      expect(
        LogService.instance.entries.first.sensitivity,
        LogSensitivity.normal,
      );
    });

    test('sensitivity flag is preserved on the entry', () {
      LogService.instance.log(
        'Test',
        'sec',
        sensitivity: LogSensitivity.sensitive,
      );
      expect(
        LogService.instance.sensitiveEntries.first.sensitivity,
        LogSensitivity.sensitive,
      );
    });
  });
}
