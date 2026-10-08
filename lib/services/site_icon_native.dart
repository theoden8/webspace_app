import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

/// Android: turns on WebView favicon downloads (`SiteIconPlugin.kt`), without
/// which `onReceivedIcon` never fires. No other platform delivers the
/// callback, so this is a no-op there.
class SiteIconNative {
  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/site_icon');
  static bool _enabled = false;
  static final SingleFlight<(), void> _enabling = SingleFlight();

  /// A failed attempt is made again by the next caller.
  static Future<void> ensureEnabled() {
    if (!hostIsAndroid || _enabled) return Future.value();
    return _enabling.run((), () async {
      try {
        await _channel.invokeMethod<bool>('enable');
        _enabled = true;
      } on PlatformException catch (e) {
        LogTag.icon.warning('Enabling WebView favicons failed: $e');
      }
    });
  }
}
