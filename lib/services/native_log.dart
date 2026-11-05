import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// Lines the Android code writes (`AppLog.kt`), filed in this log where the
/// user reads them (DEVTOOLS-014): a failure native code catches is named
/// here with its message and causes.
///
/// Each is kept in memory only. A line that names nothing of the user's has
/// already gone to logcat natively, so it is not printed again.
abstract final class NativeLog {
  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/app_log');

  /// Takes the lines from now on, and those written before, as far back as
  /// the native side keeps them.
  static Future<void> listen() async {
    if (!hostIsAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'lines') file(call.arguments);
    });
    await _channel.invokeMethod<void>('ready');
  }

  /// Files each line of [lines], as the channel carries them.
  static void file(Object? lines) {
    if (lines is! List) return;
    for (final line in lines) {
      if (line case {
        'level': final String level,
        'tag': final String tag,
        'message': final String message,
      }) {
        final into = LogTag.values.asNameMap()[tag];
        if (into == null) {
          LogTag.boot.warning('a native line under the unknown tag "$tag": '
              '$message', sensitive: true);
          continue;
        }
        switch (level) {
          case 'debug':
            into.debug(message, sensitive: true);
          case 'info':
            into.info(message, sensitive: true);
          default:
            into.warning(message, sensitive: true);
        }
      }
    }
  }
}
