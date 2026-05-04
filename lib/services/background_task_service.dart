import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// Dart-side bridge to the iOS native background task plugin
/// (`ios/Runner/BackgroundTaskPlugin.swift`). Implements NOTIF-005-I:
///
///   - [beginGracePeriod] — wraps the app's transition to background in
///     `UIApplication.beginBackgroundTask`, buying ~30 seconds of CPU time
///     before iOS suspends the process. Used by the lifecycle handler to
///     keep notification webviews polling for one last burst.
///
///   - [endGracePeriod] — releases the grace task (called on resume; iOS
///     also auto-ends via the expiration handler if we don't).
///
///   - [scheduleNextRefresh] — submits a `BGAppRefreshTaskRequest` so iOS
///     wakes us up opportunistically (typically every 15-30 minutes) to
///     reload notification sites. The native handler invokes
///     [onBackgroundRefresh] in Dart; the consumer calls [bgRefreshDidComplete]
///     when done so iOS can finalize the task.
///
/// On non-iOS platforms every method is a no-op — Android keeps webviews
/// alive via a foreground service (NOTIF-005-A); other platforms have no
/// suspension contract.
class BackgroundTaskService {
  static final instance = BackgroundTaskService._();
  BackgroundTaskService._();

  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/background_task');

  /// Called by the native side when iOS hands the app a BGAppRefreshTask.
  /// The consumer (main.dart) should reload every notification webview so
  /// page JS gets a chance to fire pending notifications, then call
  /// [bgRefreshDidComplete].
  Future<void> Function()? onBackgroundRefresh;

  bool _initialized = false;

  /// Wires the method-call handler. Call once during app startup, after
  /// the first frame, before the first lifecycle transition.
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onBackgroundRefresh':
          LogService.instance
              .log('BackgroundTask', 'BGAppRefreshTask fired — reloading notif sites');
          try {
            final cb = onBackgroundRefresh;
            if (cb != null) {
              await cb();
            }
            await bgRefreshDidComplete(success: true);
          } catch (e, st) {
            LogService.instance.log(
              'BackgroundTask',
              'BGAppRefreshTask handler threw: $e\n$st',
              level: LogLevel.error,
            );
            await bgRefreshDidComplete(success: false);
          }
          return null;
      }
      return null;
    });
  }

  Future<void> beginGracePeriod() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('beginGracePeriod');
      LogService.instance.log(
          'BackgroundTask', 'Started ~30s grace period for notification flush');
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'beginGracePeriod failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> endGracePeriod() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('endGracePeriod');
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'endGracePeriod failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> scheduleNextRefresh() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('scheduleRefresh');
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'scheduleRefresh failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> cancelScheduledRefreshes() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('cancelScheduledRefreshes');
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'cancelScheduledRefreshes failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> bgRefreshDidComplete({required bool success}) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('bgRefreshDidComplete', {'success': success});
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'bgRefreshDidComplete failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }
}
