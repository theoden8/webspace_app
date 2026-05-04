import 'dart:io';
import 'package:flutter/services.dart';

class ShareIntentService {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/share_intent');

  /// Reads any URL delivered to the app via an inbound share / VIEW intent
  /// and clears it from the native side so the same URL is not handed out
  /// twice. Returns null if no inbound URL is pending.
  static Future<String?> consumeLaunchUrl() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod('consumeLaunchUrl');
      return result is String ? result : null;
    } on PlatformException {
      return null;
    }
  }
}
