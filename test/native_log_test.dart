import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/native_log.dart';

/// DEVTOOLS-014: a line the Android code writes is filed in the app's log
/// under the tag it names, kept in memory only. The native half, its order
/// and its catch-up for a late listener, is `AppLogTest.kt`; that each
/// native tag names one here is `test/js/native_log.test.js`.
void main() {
  setUp(LogService.instance.resetForTest);

  test('DEVTOOLS-014: a native line is filed under its tag, memory only', () {
    NativeLog.file([
      {
        'level': 'warning',
        'tag': 'proxyRelay',
        'message': 'reading a client failed: IOException: Connection reset',
      },
      {'level': 'debug', 'tag': 'location', 'message': 'no fix yet'},
    ]);
    final relay = LogService.instance.recent({LogTag.proxyRelay}).single;
    expect(relay.message, contains('IOException: Connection reset'));
    expect(relay.level, LogLevel.warning);
    expect(relay.sensitivity, LogSensitivity.sensitive,
        reason: 'a native line can name a host, so it is never written');
    expect(LogService.instance.recent({LogTag.location}).single.level,
        LogLevel.debug);
  });

  test('a native line under a tag this build lacks is still filed', () {
    NativeLog.file([
      {'level': 'info', 'tag': 'noSuchTag', 'message': 'kept'},
      {'tag': 'proxyRelay'},
      'not a line',
    ]);
    final kept = LogService.instance.recent({LogTag.boot}).single;
    expect(kept.message, contains('"noSuchTag"'));
    expect(kept.message, contains('kept'));
    expect(LogService.instance.recent({LogTag.proxyRelay}), isEmpty);
  });
}
