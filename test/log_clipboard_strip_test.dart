import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';

/// The Logs tab "Copy" button routes through [LogService.formatForClipboard],
/// which must drop sensitive entries even when the tab is showing them: the
/// system clipboard syncs off-device, so it falls under the same contract as
/// [LogService.export] ("sensitive never leaves the device").
void main() {
  LogEntry entry(String tag, String message, LogSensitivity s) => LogEntry(
        timestamp: DateTime(2026, 1, 1, 12, 0, 0),
        tag: tag,
        message: message,
        level: LogLevel.info,
        sensitivity: s,
      );

  test('formatForClipboard omits sensitive entries but keeps normal ones', () {
    final entries = [
      entry('Nav', 'app started', LogSensitivity.normal),
      entry('Cookie', 'siteId=abc host=github.com proxy=1.2.3.4:8080',
          LogSensitivity.sensitive),
      entry('Theme', 'dark mode on', LogSensitivity.normal),
    ];

    final out = LogService.formatForClipboard(entries);

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
}
