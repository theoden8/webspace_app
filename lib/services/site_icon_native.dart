import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// Android: turns on WebView favicon downloads (`SiteIconPlugin.kt`), without
/// which `onReceivedIcon` never fires. No other platform delivers the
/// callback, so this is a no-op there.
class SiteIconNative {
  static const MethodChannel _channel =
      MethodChannel('org.codeberg.theoden8.webspace/site_icon');
  static Future<void>? _enabled;

  static Future<void> ensureEnabled() {
    if (!hostIsAndroid) return Future.value();
    return _enabled ??= _channel.invokeMethod<bool>('enable').then(
      (_) {},
      onError: (Object e) {
        _enabled = null;
        LogService.instance.log(
          'Icon',
          'Enabling WebView favicons failed: $e',
          level: LogLevel.warning,
        );
      },
    );
  }
}
