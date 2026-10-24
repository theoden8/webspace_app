import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';

/// Whether a remote's D-pad, not a touchscreen, drives this device
/// (NAV-016): Android TV, or an Android device without a touchscreen.
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
    try {
      _driven = await _channel.invokeMethod<bool>('drivenByRemote') ?? false;
    } on PlatformException {
      _driven = false;
    } on MissingPluginException {
      _driven = false;
    }
  }
}
