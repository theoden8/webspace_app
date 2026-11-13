import 'package:flutter/services.dart';
import 'package:webspace/services/channel_reply.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

/// The header Android draws over a desktop window (NAV-019), which the app
/// bar runs under: its buttons are drawn for the app's brightness, told here
/// as it changes.
class WindowCaption {
  WindowCaption({bool? drawn, MethodChannel? channel})
      : _drawn = drawn ?? hostIsAndroid,
        _channel = channel ?? _defaultChannel;

  static final instance = WindowCaption();

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/window_caption');

  final bool _drawn;
  final MethodChannel _channel;
  Brightness? _told;

  Future<void> follow(Brightness brightness) async {
    if (!_drawn || brightness == _told) return;
    _told = brightness;
    switch (await _channel.ask<void>(
      'setLight',
      arguments: switch (brightness) {
        Brightness.light => true,
        Brightness.dark => false,
      },
    )) {
      case Answered():
        break;
      case PlatformRefused(:final error):
        LogTag.lifecycle.error('Window caption: ${error.code}');
      case NoPlugin():
        // An engine without the activity's plugins draws no window.
        break;
    }
  }
}
