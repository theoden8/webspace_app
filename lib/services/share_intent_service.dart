import 'dart:io';
import 'package:flutter/services.dart';

class InboundHtmlShare {
  final String content;
  final String? title;
  final String? sourceUri;
  const InboundHtmlShare({
    required this.content,
    this.title,
    this.sourceUri,
  });
}

class ShareIntentService {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/share_intent');

  /// Reads any URL delivered to the app via an inbound share / VIEW intent
  /// and clears it from the native side so the same URL is not handed out
  /// twice. Returns null if no inbound URL is pending.
  static Future<String?> consumeLaunchUrl() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod('consumeLaunchUrl');
      return result is String ? result : null;
    } on PlatformException {
      return null;
    }
  }

  /// Reads any HTML file payload delivered via `text/html` ACTION_SEND.
  /// Cleared on the native side after one read. Returns null when no
  /// HTML share is pending or the platform doesn't support it.
  static Future<InboundHtmlShare?> consumeLaunchHtml() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod('consumeLaunchHtml');
      if (result is! Map) return null;
      final content = result['content'];
      if (content is! String || content.isEmpty) return null;
      return InboundHtmlShare(
        content: content,
        title: result['title'] is String ? result['title'] as String : null,
        sourceUri:
            result['sourceUri'] is String ? result['sourceUri'] as String : null,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Native side hasn't shipped the HTML branch yet; ignore.
      return null;
    }
  }
}
