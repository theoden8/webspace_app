import 'package:flutter/services.dart';

/// The system UI mode full screen asks the platform for (FS-011).
///
/// Under `immersiveSticky` a swipe reveals the system bars as transient
/// overlays that report no insets, so nothing the app keeps at a screen edge
/// can move out from under them. Under `immersive` a revealed bar is a real
/// one: the layout insets around it, and the app hides it again after
/// [kRevealedSystemBarsHideDelay]. Sticky is kept for a full screen that shows
/// none of the app's own controls.
SystemUiMode fullscreenSystemUiMode({
  required bool tabStripInFullscreen,
  required bool tabBarButton,
  required bool kioskLocked,
}) {
  if (kioskLocked) return SystemUiMode.immersiveSticky;
  return tabStripInFullscreen || tabBarButton
      ? SystemUiMode.immersive
      : SystemUiMode.immersiveSticky;
}

/// How long bars the user revealed under `immersive` stay up before the app
/// hides them again, about as long as the system keeps sticky ones up.
const kRevealedSystemBarsHideDelay = Duration(seconds: 3);
