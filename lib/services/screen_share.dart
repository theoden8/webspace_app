/// The device screen shared into a page (SHARE-017, SHARE-018): at most one
/// share at a time, the webview it was started for, its frames, and every way
/// it ends.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/site_ids.dart';

/// The webview a share was started for: the site it runs as, and the native
/// webview, so a nested screen of the same site is a different owner.
typedef ShareOwner = ({SiteId site, String view});

/// What the page asked of the surface, already bounded: a cap on each side (0
/// for none) and the frames per second it wants.
typedef ShareRequest = ({int maxWidth, int maxHeight, int fps});

/// The surface a started share serves.
typedef ShareSize = ({int width, int height});

/// The page bridge a real share runs over, named once for the shim and the
/// handlers (`buildCaptureShim`, `PageHandlers`).
abstract final class ShareHandlers {
  static const String start = 'webScreenShareStart';
  static const String frame = 'webScreenShareFrame';
  static const String stop = 'webScreenShareStop';
}

/// What bounds a share whatever the page asks: every frame crosses the bridge
/// as a JPEG, so these are what bound its bandwidth.
abstract final class ShareLimits {
  static const int maxLongSide = 1280;
  static const int maxFps = 15;
}

/// The page's `getDisplayMedia` constraints as the shim forwards them. Read
/// by pattern, so a page that sends anything else gets the defaults.
ShareRequest shareRequestFromPage(Object? args) {
  int dim(Object? v) => v is int && v > 0 ? v.clamp(1, 8192) : 0;
  return switch (args) {
    {'maxWidth': final w, 'maxHeight': final h, 'fps': final int fps} => (
      maxWidth: dim(w),
      maxHeight: dim(h),
      fps: fps.clamp(1, ShareLimits.maxFps),
    ),
    _ => (maxWidth: 0, maxHeight: 0, fps: ShareLimits.maxFps),
  };
}

/// One answer to the page's frame pull.
sealed class ShareFrame {
  const ShareFrame();

  /// What the shim reads: `{seq, jpeg}`, `{seq}`, or `{ended: true}`.
  Map<String, Object> toBridgeJson();
}

/// A frame newer than the one the page holds.
final class FrameReady extends ShareFrame {
  const FrameReady({required this.seq, required this.jpeg});

  final int seq;
  final Uint8List jpeg;

  @override
  Map<String, Object> toBridgeJson() => {'seq': seq, 'jpeg': base64Encode(jpeg)};
}

/// Nothing new arrived while the pull waited; the page asks again.
final class NoNewFrame extends ShareFrame {
  const NoNewFrame(this.seq);

  final int seq;

  @override
  Map<String, Object> toBridgeJson() => {'seq': seq};
}

/// The share is over, or was never this page's.
final class ShareEnded extends ShareFrame {
  const ShareEnded();

  @override
  Map<String, Object> toBridgeJson() => const {'ended': true};
}

/// Android's side of a share: its capture prompt, the projection and the
/// foreground service that has to hold it.
abstract interface class ScreenShareNative {
  /// Shows Android's capture prompt and starts the share. Null when the user
  /// declines, or the projection cannot start.
  Future<ShareSize?> start({
    required ShareRequest request,
    required ShareNotice notice,
  });

  /// The newest frame after [after], waiting a moment for one.
  Future<ShareFrame> frame({required int after});

  Future<void> stop();

  /// Called when the share ends without the app asking: the user stopped it
  /// from Android's notification or status bar, or the system revoked it.
  set onEnded(void Function() ended);
}

/// The one live share, and who may read it.
///
/// A share ends when its page stops its track, when the site leaves the
/// screen ([endSite], from the deactivation stop), when the document that
/// started it goes ([endView]), when the user stops it from Android's UI, and
/// when no page has pulled a frame for [idle]: a page that is gone, or frozen,
/// is no reason to keep the screen captured.
final class ScreenShare {
  ScreenShare({
    required ScreenShareNative native,
    this.idle = const Duration(seconds: 10),
    DateTime Function() now = DateTime.now,
  })  : _native = native,
        _now = now {
    _native.onEnded = _endedByUser;
  }

  static final ScreenShare instance =
      ScreenShare(native: ChannelScreenShareNative());

  final ScreenShareNative _native;
  final DateTime Function() _now;
  final Duration idle;

  /// The owner of the share Android is running.
  ShareOwner? _live;

  /// A start waiting on Android's prompt. Only one prompt can be up, and an
  /// end for its site that lands while it is up cancels it.
  ShareOwner? _pending;
  bool _pendingCancelled = false;

  DateTime _lastPull = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _watchdog;

  /// Whether [site] holds the live share. Its page keeps running while the app
  /// is in the background, which is what a share is for.
  bool sharing(SiteId site) => _live?.site == site;

  /// Starts a share for [owner], ending any other first. Null when the user
  /// declined Android's prompt, another prompt is already up, or the site
  /// left the screen while it was.
  Future<ShareSize?> start(
    ShareOwner owner, {
    required ShareRequest request,
    required ShareNotice notice,
  }) async {
    if (_pending != null) return null;
    _pending = owner;
    _pendingCancelled = false;
    final ShareSize? size;
    try {
      if (_live != null) await _end(reason: 'a new share');
      if (_pendingCancelled) return null;
      size = await _native.start(request: request, notice: notice);
    } finally {
      _pending = null;
    }
    if (size == null) return null;
    if (_pendingCancelled) {
      await _native.stop();
      LogTag.screenShare.debug('Share started after its site left the screen; stopped');
      return null;
    }
    _live = owner;
    _lastPull = _now();
    _watchdog = Timer.periodic(idle ~/ 4, (_) => _checkIdle());
    LogTag.screenShare.debug('Share started at ${size.width}x${size.height}');
    return size;
  }

  /// The newest frame for [owner]'s page, or [ShareEnded] when the share is
  /// over or belongs to another webview.
  Future<ShareFrame> frame(ShareOwner owner, {required int after}) async {
    if (_live != owner) return const ShareEnded();
    _lastPull = _now();
    final frame = await _native.frame(after: after);
    _lastPull = _now();
    if (_live != owner) return const ShareEnded();
    if (frame is ShareEnded) _clear(reason: 'Android ended it');
    return frame;
  }

  /// The page stopped its track.
  Future<void> stop(ShareOwner owner) async {
    if (_live == owner) await _end(reason: 'the page stopped it');
  }

  /// [site] left the screen, or its webview went (SHARE-017).
  Future<void> endSite(SiteId site) async {
    if (_pending?.site == site) _pendingCancelled = true;
    if (_live?.site == site) await _end(reason: 'its site left the screen');
  }

  /// The document that started the share in [view] was replaced.
  Future<void> endView(String view) async {
    if (_pending?.view == view) _pendingCancelled = true;
    if (_live?.view == view) await _end(reason: 'its page navigated away');
  }

  void _checkIdle() {
    if (_live == null) return;
    if (_now().difference(_lastPull) < idle) return;
    unawaited(_end(reason: 'no page read it for ${idle.inSeconds}s'));
  }

  void _endedByUser() => _clear(reason: 'Android ended it');

  Future<void> _end({required String reason}) async {
    if (_live == null) return;
    _clear(reason: reason);
    await _native.stop();
  }

  void _clear({required String reason}) {
    if (_live == null) return;
    _live = null;
    _watchdog?.cancel();
    _watchdog = null;
    LogTag.screenShare.debug('Share ended: $reason');
  }
}

/// [ScreenShareNative] over `ScreenSharePlugin` (Android).
final class ChannelScreenShareNative implements ScreenShareNative {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/screen_share');

  void Function()? _onEnded;

  @override
  set onEnded(void Function() ended) => _onEnded = ended;

  @override
  Future<ShareSize?> start({
    required ShareRequest request,
    required ShareNotice notice,
  }) async {
    // Set here rather than at construction, so code that only asks whether a
    // share is live needs no platform binding.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'ended') _onEnded?.call();
    });
    try {
      final reply = await _channel.invokeMethod<Object?>('start', {
        'maxWidth': request.maxWidth,
        'maxHeight': request.maxHeight,
        'maxLongSide': ShareLimits.maxLongSide,
        'fps': request.fps,
        'title': notice.title,
        'text': notice.text,
        'stop': notice.stop,
      });
      return switch (reply) {
        {'width': final int width, 'height': final int height}
            when width > 0 && height > 0 =>
          (width: width, height: height),
        _ => null,
      };
    } on PlatformException catch (e) {
      LogTag.screenShare.debug('Share failed to start: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<ShareFrame> frame({required int after}) async {
    try {
      final reply =
          await _channel.invokeMethod<Object?>('frame', {'after': after});
      return switch (reply) {
        {'seq': final int seq, 'jpeg': final Uint8List jpeg} =>
          FrameReady(seq: seq, jpeg: jpeg),
        {'seq': final int seq} => NoNewFrame(seq),
        _ => const ShareEnded(),
      };
    } on PlatformException {
      return const ShareEnded();
    } on MissingPluginException {
      return const ShareEnded();
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      LogTag.screenShare.debug('Share failed to stop: ${e.code} ${e.message}');
    } on MissingPluginException {
      return;
    }
  }
}
