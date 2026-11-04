import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';

/// What a navigation the platform asks about says of itself, read alike on
/// every host.
extension NavigationActionReading on inapp.NavigationAction {
  /// Whether the user caused it. Android and Linux report the engine's
  /// user-gesture flag; Apple hosts report only the navigation type, so a
  /// click a script intercepts reads as script-driven there (NESTED-004).
  bool get byUserGesture {
    if (hostIsAndroid || hostIsLinux) {
      return hasGesture ?? true;
    }
    if (hostIsIOS || hostIsMacOS) {
      return navigationType == inapp.NavigationType.LINK_ACTIVATED ||
          navigationType == inapp.NavigationType.FORM_SUBMITTED;
    }
    return true;
  }

  /// Whether loading its URL again makes the request it asks for: no form
  /// submission, which may carry a body, and no method but GET. Android asks
  /// about GET navigations alone, and the Linux plugin reports every request
  /// as GET, so a form there is known by its type (NESTED-016, NESTED-017).
  bool get replayable {
    if (navigationType == inapp.NavigationType.FORM_SUBMITTED ||
        navigationType == inapp.NavigationType.FORM_RESUBMITTED) {
      return false;
    }
    final method = request.method;
    return method == null || method.toUpperCase() == 'GET';
  }
}
