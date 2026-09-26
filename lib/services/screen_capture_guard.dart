import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';

/// Whether the window is withheld from screenshots, recordings and the
/// recent-apps preview (SCREENBLOCK-002): the app-wide switch, or the switch
/// of the site on screen. With no site on screen (the webspaces list) only the
/// app-wide switch counts.
bool screenCaptureBlocked({
  required bool appWide,
  required bool? siteOnScreen,
}) =>
    appWide || (siteOnScreen ?? false);

/// Bridge to [ScreenCapturePlugin.kt], which sets `FLAG_SECURE` on the
/// activity window.
class ScreenCaptureGuard {
  ScreenCaptureGuard({bool? supported, MethodChannel? channel})
      : _supported = supported ?? isSupported,
        _channel = channel ?? _defaultChannel;

  static const _defaultChannel =
      MethodChannel('org.codeberg.theoden8.webspace/screen_capture');

  /// Android only (SCREENBLOCK-001). iOS has no public API that keeps a
  /// screenshot out, and on macOS 15+ ScreenCaptureKit ignores
  /// `NSWindow.sharingType`, so a switch there would promise what it cannot do.
  static bool get isSupported => debugSupportedOverride ?? hostIsAndroid;

  @visibleForTesting
  static bool? debugSupportedOverride;

  /// The app-wide switch. Held here rather than threaded through the site
  /// settings screens, which read it to show a site's own switch as already
  /// covered.
  static bool appWideEnabled = false;

  final bool _supported;
  final MethodChannel _channel;
  bool? _requested;

  /// Sends [blocked] to the window when it differs from the last value sent.
  /// Cheap to call on every build.
  Future<void> apply(bool blocked) async {
    if (!_supported || blocked == _requested) return;
    _requested = blocked;
    try {
      await _channel.invokeMethod<void>('setBlocked', {'blocked': blocked});
    } on PlatformException {
      // Unknown window state: let the next call send again.
      if (_requested == blocked) _requested = null;
    } on MissingPluginException {
      // No plugin on this host; resending every build would not change that.
    }
  }
}
