import 'dart:async';
import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:webspace/services/background_log.dart';
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
///     minimum, `NetworkType.CONNECTED`, first run one interval out so a
///     freshly scheduled refresh does not reload the site the user just
///     opened). The system fires whenever it deems appropriate.
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

  bool get _enabled => hostIsIOS || hostIsAndroid;

  /// Wires the method-call handler. Call once during app startup, after
  /// the first frame, before the first lifecycle transition.
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    if (!_enabled) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onBackgroundRefresh':
          final lifecycle =
              SchedulerBinding.instance.lifecycleState?.name ?? 'unknown';
          BackgroundLog.instance.record(LogTag.backgroundTask,
              'background refresh fired (app $lifecycle) — reloading notif sites');
          final watch = Stopwatch()..start();
          try {
            final cb = onBackgroundRefresh;
            if (cb != null) {
              await cb();
            }
            BackgroundLog.instance.record(LogTag.backgroundTask,
                'background refresh handled in ${watch.elapsedMilliseconds}ms');
            await bgRefreshDidComplete(success: true);
          } catch (e, st) {
            // The message can quote a page URL; only its type is kept on disk.
            BackgroundLog.instance.record(
              LogTag.backgroundTask,
              'background refresh handler threw ${e.runtimeType}',
              level: LogLevel.error,
              sensitive: 'background refresh handler threw: $e\n$st',
            );
            await bgRefreshDidComplete(success: false);
          }
          return null;
      }
      return null;
    });
    // Android: an engine the refresh worker started for a wake (NOTIF-016)
    // sends the refresh only once this handler is installed.
    if (hostIsAndroid) unawaited(_announceReady());
  }

  Future<void> _announceReady() async {
    try {
      await _channel.invokeMethod('backgroundRefreshReady');
    } on PlatformException catch (e) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        'backgroundRefreshReady failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> beginGracePeriod() async {
    if (!hostIsIOS) return;
    try {
      await _channel.invokeMethod('beginGracePeriod');
      LogTag.backgroundTask.debug(
          'Started ~30s grace period for notification flush');
    } on PlatformException catch (e) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        'beginGracePeriod failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  Future<void> endGracePeriod() async {
    if (!hostIsIOS) return;
    try {
      await _channel.invokeMethod('endGracePeriod');
    } on PlatformException catch (e) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
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
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
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
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
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
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        'bgRefreshDidComplete failed: ${e.message}',
        level: LogLevel.warning,
      );
    }
  }

  bool? _backgroundAudioActive;

  /// BGAUDIO-003: iOS-only. Switches the shared `AVAudioSession` to the
  /// `.playback` category while any loaded site has background audio
  /// enabled (and back to `.ambient` when none does). `.playback` plus the
  /// `audio` UIBackgroundModes entry is what lets WKWebView media keep
  /// running after the app leaves the foreground; `.ambient` restores the
  /// respect-the-silent-switch default so ordinary sites don't blast
  /// through a muted phone. Android needs no equivalent — WebView audio
  /// keeps playing as long as the process (and its JS) stays alive.
  Future<void> setBackgroundAudioActive(bool active) async {
    if (!hostIsIOS) return;
    if (_backgroundAudioActive == active) return;
    _backgroundAudioActive = active;
    try {
      await _channel
          .invokeMethod('setBackgroundAudioActive', {'active': active});
      BackgroundLog.instance.record(
          LogTag.backgroundTask, 'Background audio session active=$active');
    } on PlatformException catch (e) {
      BackgroundLog.instance.record(
        LogTag.backgroundTask,
        'setBackgroundAudioActive failed: ${e.message}',
        level: LogLevel.warning,
      );
    } on MissingPluginException {
      // Older native side without the handler; harmless.
    }
  }
}
