import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';

/// Whether a hardware keyboard is attached to an Android device (NAV-019):
/// the configuration's, which changes as one is plugged in or folded away,
/// so it is kept as it changes. A desktop has one by definition and does not
/// ask.
abstract final class KeyboardInput {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/keyboard_input');

  static final attached = ValueNotifier<bool>(false);

  /// Reads the configuration and follows it. Without the plugin (a
  /// background wake's engine, which has no activity) there is no keyboard
  /// to follow.
  static Future<void> probe() async {
    if (!hostIsAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call case MethodCall(method: 'attachedChanged', arguments: final bool now)) {
        attached.value = now;
      }
    });
    try {
      attached.value =
          await _channel.invokeMethod<bool>('attached') ?? false;
    } on PlatformException {
      attached.value = false;
    } on MissingPluginException {
      attached.value = false;
    }
  }
}
