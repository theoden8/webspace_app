import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/app_prefs.dart';

/// The app's one desktop window, which a close may only hide so the sites keep
/// running and can notify (NOTIF-018). The runner decides the close as it
/// lands, from what this tells it of [AppPref.keepRunningWhenClosed]: the Dock
/// icon on macOS and a second launch on Linux bring it back, and so does a
/// click on a notification, through [show].
class DesktopWindow {
  DesktopWindow({
    bool? offered,
    MethodChannel? channel,
    Future<void> Function()? exit,
  })  : _offered = offered ?? DesktopWindow.offered,
        _channel = channel ?? _defaultChannel,
        _exit = exit ?? _exitApplication;

  static final instance = DesktopWindow();

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/desktop_window');

  /// Where the runner can hide its window and be asked for it again: the
  /// Dock on macOS, a second launch of the one instance on Linux
  /// (PLATFORM-011).
  static bool get offered => hostIsMacOS || hostIsLinux;

  final bool _offered;
  final MethodChannel _channel;
  final Future<void> Function() _exit;

  /// Tells the runner the setting now and on every change.
  void start() {
    if (!_offered) return;
    AppPref.keepRunningWhenClosed.listenable.addListener(_tell);
    _tell();
  }

  @visibleForTesting
  void stop() => AppPref.keepRunningWhenClosed.listenable.removeListener(_tell);

  void _tell() {
    final keep = AppPref.keepRunningWhenClosed.value;
    unawaited(_invoke('setKeepRunningWhenClosed', args: {'keep': keep})
        .then((told) {
      if (told) LogTag.lifecycle.debug('Desktop window: a close hides it: $keep');
    }));
  }

  /// Brings a hidden window back, in front.
  Future<void> show() async {
    if (_offered) await _invoke('show', args: null);
  }

  /// Leaves the app, where a close of the window may only hide it.
  Future<void> quit() => _exit();

  static Future<void> _exitApplication() async {
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  /// Whether the runner took [method].
  Future<bool> _invoke(String method, {required Object? args}) async {
    try {
      await _channel.invokeMethod<void>(method, args);
      return true;
    } on PlatformException catch (e) {
      LogTag.lifecycle.error('Desktop window $method failed: ${e.code}');
    } on MissingPluginException {
      // Such a runner closes as it always has, whatever the setting says.
      LogTag.lifecycle.warning('Desktop window $method: the runner has no channel');
    }
    return false;
  }
}
