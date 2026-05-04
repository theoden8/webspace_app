import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// Dart-side bridge to [WebSpaceBackgroundPollPlugin] (Android
/// foreground service for NOTIF-005-A). The service holds the app
/// process alive across backgrounding so notification sites' webviews
/// keep executing JS — Android otherwise eventually freezes the
/// renderer once the activity is no longer visible.
///
/// Exposes:
///
///   - [start] — `startForeground(...)` with a persistent notification
///     "WebSpace is checking N sites for updates". Idempotent: a second
///     [start] with the same count is a no-op on the native side.
///
///   - [stop] — stops the service and dismisses the persistent
///     notification. Idempotent.
///
/// On non-Android platforms every method is a no-op. iOS handles the
/// equivalent via `BGAppRefreshTask`; desktop has no suspension contract.
class AndroidForegroundService {
  static final instance = AndroidForegroundService._();
  AndroidForegroundService._();

  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/background-poll');

  bool _running = false;
  int _lastCount = 0;

  bool get running => _running;

  Future<void> start(int siteCount) async {
    if (!Platform.isAndroid) return;
    if (siteCount <= 0) {
      await stop();
      return;
    }
    if (_running && siteCount == _lastCount) return;
    try {
      await _channel.invokeMethod('start', {'count': siteCount});
      _running = true;
      _lastCount = siteCount;
      LogService.instance.log(
        'BackgroundPoll',
        'Android foreground service started for $siteCount site(s)',
      );
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundPoll',
        'Foreground service start failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_running) return;
    try {
      await _channel.invokeMethod('stop');
      LogService.instance.log(
        'BackgroundPoll',
        'Android foreground service stopped',
      );
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundPoll',
        'Foreground service stop failed: ${e.message}',
        level: LogLevel.warning,
      );
    } finally {
      _running = false;
      _lastCount = 0;
    }
  }
}
