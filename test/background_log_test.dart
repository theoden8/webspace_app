import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/background_log.dart';
import 'package:webspace/services/log_service.dart';

/// Models the native file: a list of JSON lines the plugin appends to, which
/// exists only while enabled.
class _FakeNative implements BackgroundLogNative {
  _FakeNative({this.available = true});

  @override
  final bool available;

  List<String>? file;
  final appended = <LogEntry>[];
  bool failReads = false;
  List<MapEntry<String, String>> state = const [];

  @override
  Future<void> setEnabled({required bool enabled}) async {
    if (enabled) {
      file ??= [];
    } else {
      file = null;
    }
  }

  @override
  Future<void> append(LogEntry entry) async {
    appended.add(entry);
    file?.add(jsonEncode({
      't': entry.timestamp.millisecondsSinceEpoch,
      'l': entry.level.name,
      'g': entry.tag,
      'm': entry.message,
    }));
  }

  /// A line the native side wrote by itself.
  void nativeRecord(DateTime t, {required String message}) {
    file?.add(jsonEncode(
        {'t': t.millisecondsSinceEpoch, 'l': 'info', 'g': 'Android', 'm': message}));
  }

  @override
  Future<List<LogEntry>?> read() async {
    if (failReads) return null;
    return [for (final l in file ?? const <String>[]) ?parseBackgroundLogLine(l)];
  }

  @override
  Future<void> clear() async {
    if (file != null) file = [];
  }

  @override
  Future<List<MapEntry<String, String>>> systemState() async => state;
}

void main() {
  setUp(LogService.instance.resetForTest);

  group('DEVTOOLS-011 recording follows developer mode', () {
    test('off: nothing is kept, nothing reaches the native file', () async {
      final native = _FakeNative();
      final log = BackgroundLog(native: native);
      await log.setRecording(on: false);
      log.record(LogTag.backgroundTask,
          message: 'wake', sensitive: 'site "Mail"');
      expect(native.appended, isEmpty);
      expect(await log.entries(includeSensitive: true), isEmpty);
      // App Logs still sees the line.
      expect(LogService.instance.entries.map((e) => e.message), contains('wake'));
    });

    test('on: the entry reaches the native file', () async {
      final native = _FakeNative();
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.backgroundTask, message: 'schedule refresh');
      await Future<void>.delayed(Duration.zero);
      expect(native.file, hasLength(1));
      final entries = await log.entries(includeSensitive: false);
      expect(entries.single.message, 'schedule refresh');
    });

    test('turning it off deletes what was recorded', () async {
      final native = _FakeNative();
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.backgroundTask,
          message: 'one', sensitive: 'site "Mail"');
      await log.setRecording(on: false);
      expect(native.file, isNull);
      await log.setRecording(on: true);
      expect(await log.entries(includeSensitive: true), isEmpty);
    });
  });

  group('DEVTOOLS-011 sensitive content stays separate', () {
    test('the sensitive companion never reaches the native file', () async {
      final native = _FakeNative();
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.notification,
          message: 'notification posted (page, untagged)',
          sensitive: 'Showed notification: "Hi Bob" for siteId: abc123');
      await Future<void>.delayed(Duration.zero);
      final onDisk = native.file!.join('\n');
      expect(onDisk, isNot(contains('Hi Bob')));
      expect(onDisk, isNot(contains('abc123')));
      expect(native.appended.every((e) => e.sensitivity == LogSensitivity.normal),
          isTrue);
    });

    test('shown only on request, right after the line it explains', () async {
      final log = BackgroundLog(native: _FakeNative());
      await log.setRecording(on: true);
      log.record(LogTag.backgroundTask, message: 'wake site 1/1: loaded',
          sensitive: 'wake site 1/1 is "Mail"');
      await Future<void>.delayed(Duration.zero);
      expect((await log.entries(includeSensitive: false)).map((e) => e.message),
          ['wake site 1/1: loaded']);
      final both = await log.entries(includeSensitive: true);
      expect(both.map((e) => e.message),
          ['wake site 1/1: loaded', 'wake site 1/1 is "Mail"']);
      expect(both.last.sensitivity, LogSensitivity.sensitive);
    });

    test('format drops sensitive entries unless asked', () async {
      final log = BackgroundLog(native: _FakeNative());
      await log.setRecording(on: true);
      log.record(LogTag.backgroundTask,
          message: 'normal line', sensitive: 'names "Mail"');
      await Future<void>.delayed(Duration.zero);
      final all = await log.entries(includeSensitive: true);
      expect(BackgroundLog.format(all), isNot(contains('Mail')));
      expect(BackgroundLog.format(all), contains('normal line'));
      expect(BackgroundLog.format(all, includeSensitive: true), contains('Mail'));
      final withState = BackgroundLog.format(all,
          state: const [MapEntry('ios.lowPowerMode', 'true')]);
      expect(withState, startsWith('System state:\n  ios.lowPowerMode: true\n'));
      expect(withState, contains('normal line'));
    });
  });

  group('DEVTOOLS-011 the native file outlives the process', () {
    test('entries from an earlier process and native-only steps show',
        () async {
      final native = _FakeNative();
      await native.setEnabled(enabled: true);
      native.nativeRecord(DateTime(2026, 10, 5, 3), message: 'worker fired');
      native.nativeRecord(DateTime(2026, 10, 5, 3, 0, 1),
          message: 'no Flutter engine; refresh skipped');
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      final entries = await log.entries(includeSensitive: false);
      expect(entries.map((e) => e.message),
          ['worker fired', 'no Flutter engine; refresh skipped']);
      expect(entries.first.tag, 'Android');
    });

    test('an unreadable file falls back to this process', () async {
      final native = _FakeNative()..failReads = true;
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.lifecycle, message: 'App background');
      expect((await log.entries(includeSensitive: false)).single.message,
          'App background');
    });

    test('a platform without the native half keeps this process only',
        () async {
      final native = _FakeNative(available: false);
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.lifecycle, message: 'App background');
      expect(native.appended, isEmpty);
      expect((await log.entries(includeSensitive: false)).single.message,
          'App background');
    });

    test('clear empties the file but keeps recording', () async {
      final native = _FakeNative();
      final log = BackgroundLog(native: native);
      await log.setRecording(on: true);
      log.record(LogTag.lifecycle, message: 'one');
      await Future<void>.delayed(Duration.zero);
      await log.clear();
      expect(native.file, isEmpty);
      log.record(LogTag.lifecycle, message: 'two');
      await Future<void>.delayed(Duration.zero);
      expect((await log.entries(includeSensitive: false)).single.message, 'two');
    });
  });

  group('parseBackgroundLogLine', () {
    test('reads a well-formed line', () {
      final e = parseBackgroundLogLine(
          '{"t":1759600000000,"l":"warning","g":"iOS","m":"task expired"}')!;
      expect(e.tag, 'iOS');
      expect(e.level, LogLevel.warning);
      expect(e.message, 'task expired');
    });

    test('drops what does not parse', () {
      expect(parseBackgroundLogLine('{"t":1,"g":"iOS"'), isNull);
      expect(parseBackgroundLogLine('[1,2]'), isNull);
      expect(parseBackgroundLogLine('{"t":"x","g":"iOS","m":"m"}'), isNull);
    });
  });

  test('system state lists app rows before native ones', () async {
    final native = _FakeNative()
      ..state = const [MapEntry('ios.backgroundRefreshStatus', 'denied')];
    final log = BackgroundLog(native: native)
      ..appState = () => const [MapEntry('app.notificationSitesLoaded', '0')];
    expect((await log.systemState()).map((e) => e.key),
        ['app.notificationSitesLoaded', 'ios.backgroundRefreshStatus']);
  });
}
