import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/channel_reply.dart';

import 'package:webspace/platform/host_platform.dart';

/// Whether a remote's D-pad, not a touchscreen, drives this device
/// (NAV-016): Android TV, or an Android device with neither a touchscreen
/// nor a pointer standing in for one, as a desktop's mouse does.
/// Probed in main() before the first webview is built, which reads it.
abstract final class RemoteInput {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/remote_input');

  static bool? _driven;

  @visibleForTesting
  static bool? debugDrivenOverride;

  static bool get driven => debugDrivenOverride ?? _driven ?? false;

  static Future<void> probe() async {
    if (!hostIsAndroid) {
      _driven = false;
      return;
    }
    _driven = switch (await _channel.ask<bool>('drivenByRemote')) {
      Answered(:final value) => value ?? false,
      PlatformRefused() => false,
      NoPlugin() => false,
    };
  }
}
