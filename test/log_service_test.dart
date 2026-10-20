import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';

void main() {
  setUp(() {
    LogService.instance.resetForTest();
  });

  group('console severity', () {
    late LogLevel previousLevel;
    late DebugPrintCallback previousPrinter;
    late List<String> printed;

    setUp(() {
      previousLevel = LogService.instance.consoleLevel;
      previousPrinter = debugPrint;
      printed = [];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
    });

    tearDown(() {
      debugPrint = previousPrinter;
      LogService.instance.consoleLevel = previousLevel;
    });

    test('quiet output keeps all levels in the ring and notifies listeners', () {
      final log = LogService.instance;
      log.consoleLevel = LogLevel.warning;
      var notifications = 0;
      void listen() => notifications++;
      log.addListener(listen);
      addTearDown(() => log.removeListener(listen));
      for (final level in LogLevel.values) {
        log.log(LogTag.test, message: level.name, level: level);
      }

      expect(printed, [
        '[Test/warning] warning',
        '[Test/error] error',
      ]);
      expect(log.entries.map((entry) => entry.level), LogLevel.values);
      expect(notifications, LogLevel.values.length);
      expect(log.export(), contains('[Test/debug] debug'));
      expect(log.export(), contains('[Test/info] info'));
    });

    test('verbose output can restore debug details', () {
      LogService.instance.consoleLevel = LogLevel.debug;
      LogTag.cookieIsolation.debug('Currently loaded rows: {}');
      expect(printed, [
        '[CookieIsolation/debug] Currently loaded rows: {}',
      ]);
    });

    test('sensitive errors stay silent even with verbose output', () {
      LogService.instance.consoleLevel = LogLevel.debug;
      LogTag.test.error('private detail', sensitive: true);
      expect(printed, isEmpty);
      expect(LogService.instance.sensitiveEntries.single.message,
          'private detail');
    });
  });

  for (final sensitivity in LogSensitivity.values) {
    test('${sensitivity.name} retention survives repeated buffer wraps', () {
      final printer = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
      addTearDown(() => debugPrint = printer);
      final log = LogService.instance;
      var notifications = 0;
      void listen() => notifications++;
      log.addListener(listen);
      addTearDown(() => log.removeListener(listen));
      List<LogEntry> entries() => switch (sensitivity) {
        LogSensitivity.normal => log.entries,
        LogSensitivity.sensitive => log.sensitiveEntries,
      };
      final messages = <String>[];
      List<LogEntry>? snapshot;
      for (var i = 0; i < LogService.maxEntries * 3 + 7; i++) {
        final message = '$i';
        messages.add(message);
        log.log(LogTag.test, message: message, sensitivity: sensitivity);
        if (i == 0 || (i + 1) % LogService.maxEntries <= 1) {
          expect(
            entries().map((e) => e.message),
            messages.skip(math.max(0, messages.length - LogService.maxEntries)),
          );
        }
        if (i + 1 == LogService.maxEntries) snapshot = entries();
      }
      expect(
        entries().map((e) => e.message),
        messages.skip(messages.length - LogService.maxEntries),
      );
      final saved = snapshot!;
      expect(saved.map((e) => e.message), messages.take(LogService.maxEntries));
      expect(saved.clear, throwsUnsupportedError);
      expect(notifications, messages.length);
      expect(log.allEntriesMerged, unorderedEquals(entries()));
      switch (sensitivity) {
        case LogSensitivity.normal:
          expect(log.sensitiveEntries, isEmpty);
          expect(
            log.export().split('\n').where((s) => s.isNotEmpty),
            hasLength(LogService.maxEntries),
          );
        case LogSensitivity.sensitive:
          expect(log.entries, isEmpty);
          expect(log.export(), isEmpty);
      }
      log.clear();
      expect(entries(), isEmpty);
      expect(notifications, messages.length + 1);
      log.log(LogTag.test, message: 'after clear', sensitivity: sensitivity);
      expect(entries().single.message, 'after clear');
    });

    test(
      '${sensitivity.name} recent filtering respects scan and limit after wraps',
      () {
        final printer = debugPrint;
        debugPrint = (message, {wrapWidth}) {};
        addTearDown(() => debugPrint = printer);
        final matching = <int>[];
        final count = LogService.maxEntries * 3 + 7;
        for (var i = 0; i < count; i++) {
          final tag = i % 3 == 0 ? LogTag.tabs : LogTag.test;
          LogService.instance.log(tag, message: '$i', sensitivity: sensitivity);
          if (tag == LogTag.tabs && i >= count - 31) matching.add(i);
        }
        expect(
          LogService.instance
              .recent({LogTag.tabs}, limit: 7, scan: 31)
              .map((e) => e.message),
          matching.skip(math.max(0, matching.length - 7)).map((i) => '$i'),
        );
        expect(LogService.instance.recent({LogTag.tabs}, limit: 0), isEmpty);
        expect(LogService.instance.recent({LogTag.tabs}, scan: 0), isEmpty);
      },
    );
  }

  group('LogService normal entries', () {
    test('reach the persisted entries sink', () {
      LogTag.test.debug('hello');
      expect(LogService.instance.entries, hasLength(1));
      expect(LogService.instance.entries.first.message, 'hello');
    });

    test('appear in export()', () {
      LogTag.test.debug('first');
      LogTag.test.debug('second');
      final out = LogService.instance.export();
      expect(out, contains('first'));
      expect(out, contains('second'));
    });
  });

  group('LogService sensitive entries', () {
    test('stay out of the normal entries sink', () {
      LogTag.test.debug('secret-payload', sensitive: true);
      expect(LogService.instance.entries, isEmpty);
      expect(LogService.instance.sensitiveEntries, hasLength(1));
      expect(
        LogService.instance.sensitiveEntries.first.message,
        'secret-payload',
      );
    });

    test('never reach export() (memory-only contract)', () {
      LogTag.test.debug('secret-payload', sensitive: true);
      final out = LogService.instance.export();
      expect(out, isNot(contains('secret-payload')));
    });

    test('do NOT print to the zone print stream', () {
      final captured = <String>[];
      runZoned(
        () {
          LogTag.test.debug('secret-payload', sensitive: true);
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
      LogTag.test.debug('first-normal');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      LogTag.test.debug('sensitive-mid', sensitive: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      LogTag.test.debug('last-normal');

      final merged = LogService.instance.allEntriesMerged;
      expect(merged.map((e) => e.message), [
        'first-normal',
        'sensitive-mid',
        'last-normal',
      ]);
    });

    test('are cleared on simulated process restart (resetForTest)', () {
      LogTag.test.debug('pre-restart', sensitive: true);
      expect(LogService.instance.sensitiveEntries, hasLength(1));

      // Simulate a cold launch: the in-memory ring is wiped, the toggle
      // would reset to off (UI concern), and the singleton is reused.
      LogService.instance.resetForTest();

      expect(LogService.instance.sensitiveEntries, isEmpty);
      expect(LogService.instance.entries, isEmpty);
    });

    test('clear() wipes both rings', () {
      LogTag.test.debug('normal-1');
      LogTag.test.debug('sensitive-1', sensitive: true);
      LogService.instance.clear();
      expect(LogService.instance.entries, isEmpty);
      expect(LogService.instance.sensitiveEntries, isEmpty);
    });

    test('respect the per-ring maxEntries cap', () {
      for (var i = 0; i < LogService.maxEntries + 50; i++) {
        LogTag.test.debug('sensitive-$i', sensitive: true);
      }
      expect(
        LogService.instance.sensitiveEntries,
        hasLength(LogService.maxEntries),
      );
      // The oldest entries should have rolled off.
      expect(
        LogService.instance.sensitiveEntries.first.message,
        'sensitive-50',
      );
    });
  });

  group('LogEntry shape', () {
    test('default sensitivity is normal', () {
      LogTag.test.debug('message');
      expect(
        LogService.instance.entries.first.sensitivity,
        LogSensitivity.normal,
      );
    });

    test('sensitivity flag is preserved on the entry', () {
      LogTag.test.debug('sec', sensitive: true);
      expect(
        LogService.instance.sensitiveEntries.first.sensitivity,
        LogSensitivity.sensitive,
      );
    });
  });
}
