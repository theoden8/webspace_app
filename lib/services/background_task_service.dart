import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';

/// Dart-side bridge to the platform background-task plugins. Implements
/// NOTIF-005-I (iOS, `BackgroundTaskPlugin.swift`) and NOTIF-005-A
/// (Android, `BackgroundTaskAndroidPlugin.kt`). Both speak the same
/// method-channel protocol so the call site is platform-agnostic.
///
///   - [beginGracePeriod] / [endGracePeriod] — iOS only. Wraps the
///     transition to background in `UIApplication.beginBackgroundTask`,
///     buying ~30s before iOS suspends. No-op on Android (the OS gives
///     a brief grace period implicitly; an explicit equivalent would
///     require a foreground service, which NOTIF-005-A deliberately
///     avoids).
///
///   - [scheduleNextRefresh] — submits a `BGAppRefreshTaskRequest` on
///     iOS, an `androidx.work` `PeriodicWorkRequest` on Android (15-min
///     minimum, `NetworkType.CONNECTED`). The system fires whenever it
///     deems appropriate.
///
///   - [cancelScheduledRefreshes] — cancels the iOS request / Android
///     unique work. Use when the last notification site goes away.
///
///   - [bgRefreshDidComplete] — closes out the in-flight task on the
///     native side once the Dart-side reload finishes.
///
/// On non-iOS / non-Android platforms every method is a no-op.
class BackgroundTaskService {
  static final instance = BackgroundTaskService._();
  BackgroundTaskService._();

  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/background_task');

  /// Called by the native side when iOS hands the app a BGAppRefreshTask
  /// or Android's WorkManager fires a NotificationRefreshWorker. The
  /// consumer (main.dart) reloads every notification webview, then this
  /// service auto-completes the task on the native side.
  Future<void> Function()? onBackgroundRefresh;

  bool _initialized = false;

  bool get _enabled => Platform.isIOS || Platform.isAndroid;

  /// Wires the method-call handler. Call once during app startup, after
  /// the first frame, before the first lifecycle transition.
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onBackgroundRefresh':
          LogService.instance.log(
              'BackgroundTask', 'background refresh fired — reloading notif sites');
          try {
            final cb = onBackgroundRefresh;
            if (cb != null) {
              await cb();
            }
            await bgRefreshDidComplete(success: true);
          } catch (e, st) {
            LogService.instance.log(
              'BackgroundTask',
              'background refresh handler threw: $e\n$st',
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
    if (!_enabled) return;
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
    if (!_enabled) return;
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
    if (!_enabled) return;
    try {
      await _channel
          .invokeMethod('bgRefreshDidComplete', {'success': success});
    } on PlatformException catch (e) {
      LogService.instance.log(
        'BackgroundTask',
        'bgRefreshDidComplete failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }
}
