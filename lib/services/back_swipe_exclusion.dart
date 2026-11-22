import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/channel_reply.dart';
import 'package:webspace/services/log_service.dart';

/// The strip of the screen edge the app keeps from Android's back swipe: the
/// sidebar's arrow tab, so a drag from the edge pulls the sidebar out
/// (TAB-032). The one owner of the claim: each change sends it whole, so the
/// Android side keeps nothing.
class BackSwipeExclusion {
  BackSwipeExclusion({bool? claims, MethodChannel? channel})
      : _claims = claims ?? hostIsAndroid,
        _channel = channel ?? _defaultChannel;

  static final instance = BackSwipeExclusion();

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/back_swipe_exclusion');

  final bool _claims;
  final MethodChannel _channel;
  Rect? _told;

  /// [rect], in the window's device pixels, is the app's.
  Future<void> keep(Rect rect) => _tell(rect);

  /// The edge is the system's again.
  Future<void> release() => _tell(null);

  Future<void> _tell(Rect? rect) async {
    if (!_claims || rect == _told) return;
    _told = rect;
    switch (await _channel.ask<void>('setRects', arguments: [
      if (rect != null) [rect.left, rect.top, rect.right, rect.bottom],
    ])) {
      case Answered():
        break;
      case PlatformRefused(:final error):
        LogTag.navigation.error('Back swipe exclusion: ${error.code}');
      case NoPlugin():
        // An engine without the activity's plugins draws no window.
        break;
    }
  }
}
