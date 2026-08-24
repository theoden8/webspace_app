import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';

/// [LogService.formatForClipboard] drops sensitive entries unless the caller
/// asks for them: the Logs tab only passes `includeSensitive` after the user
/// confirms the copy, and no other caller may opt in silently. Files written
/// by [LogService.export] never carry sensitive entries at all.
void main() {
  LogEntry entry(String tag, String message, LogSensitivity s) => LogEntry(
        timestamp: DateTime(2026, 1, 1, 12, 0, 0),
        tag: tag,
        message: message,
        level: LogLevel.info,
        sensitivity: s,
      );

  final mixed = [
    entry('Nav', 'app started', LogSensitivity.normal),
    entry('Cookie', 'siteId=abc host=github.com proxy=1.2.3.4:8080',
        LogSensitivity.sensitive),
    entry('Theme', 'dark mode on', LogSensitivity.normal),
  ];

  test('formatForClipboard omits sensitive entries by default', () {
    final out = LogService.formatForClipboard(mixed);

    expect(out, contains('app started'));
    expect(out, contains('dark mode on'));
    // No sensitive payload — no siteId, host, or proxy address.
    expect(out.contains('siteId=abc'), isFalse);
    expect(out.contains('github.com'), isFalse);
    expect(out.contains('1.2.3.4'), isFalse);
  });

  test('formatForClipboard is empty when every entry is sensitive', () {
    final entries = [
      entry('Cookie', 'siteId=secret', LogSensitivity.sensitive),
      entry('Proxy', 'host=10.0.0.1', LogSensitivity.sensitive),
    ];
    expect(LogService.formatForClipboard(entries).trim(), isEmpty);
  });

  test('formatForClipboard keeps every entry when includeSensitive is set', () {
    final out = LogService.formatForClipboard(mixed, includeSensitive: true);

    expect(out, contains('app started'));
    expect(out, contains('siteId=abc'));
    expect(out, contains('dark mode on'));
    expect(out.trim().split('\n'), hasLength(3));
  });

  test('export never ships sensitive entries', () {
    LogService.instance.resetForTest();
    LogService.instance.log('Nav', 'app started');
    LogService.instance.log('Cookie', 'siteId=abc',
        sensitivity: LogSensitivity.sensitive);

    final out = LogService.instance.export();

    expect(out, contains('app started'));
    expect(out.contains('siteId=abc'), isFalse);
    LogService.instance.resetForTest();
  });
}
