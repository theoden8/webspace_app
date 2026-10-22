import 'package:flutter/services.dart';
import 'package:webspace/settings/tab_strip_edge.dart';

/// The system UI a full screen asks the platform for (FS-011, FS-012).
///
/// Under `immersiveSticky` a swipe reveals the system bars as transient
/// overlays that report no insets, so nothing the app keeps at a screen edge
/// can move out from under them. Under `immersive` a revealed bar is a real
/// one: the layout insets around it, and the app hides it again after
/// [kRevealedSystemBarsHideDelay]. Sticky is kept for a full screen that shows
/// none of the app's own controls. A tab strip along the top edge keeps the
/// status bar, so the strip sits below it rather than in its place.
enum FullscreenSystemUi {
  /// Both bars hidden; a swipe shows them as transient overlays.
  barsHiddenSticky,

  /// Both bars hidden; a swiped-in bar stays, with its insets, until the app
  /// hides it again.
  barsHidden,

  /// The status bar stays and the navigation bar hides. The engine's manual
  /// mode sets no immersive flag, so on Android 11 and below the hidden
  /// navigation bar comes back on a touch, not only on a swipe.
  statusBarKept;

  /// What full screen shows: [tabStripEdge] is the edge the tab strip is on
  /// screen at, null while it is not; [tabBarButton] whether the floating
  /// button can reveal it.
  static FullscreenSystemUi of({
    required bool kioskLocked,
    required TabStripEdge? tabStripEdge,
    required bool tabBarButton,
  }) {
    if (kioskLocked) return barsHiddenSticky;
    return switch (tabStripEdge) {
      TabStripEdge.top => statusBarKept,
      TabStripEdge.bottom => barsHidden,
      null => tabBarButton ? barsHidden : barsHiddenSticky,
    };
  }

  /// Whether a bar the user swipes in stays, with its insets, until the app
  /// hides it; sticky bars hide themselves.
  bool get revealedBarsStay => switch (this) {
        barsHiddenSticky => false,
        barsHidden || statusBarKept => true,
      };

  /// Asks the platform for it: the one place full screen names a system UI
  /// mode (test/js/fullscreen_system_ui_funnel.test.js).
  Future<void> request() => switch (this) {
        barsHiddenSticky =>
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
        barsHidden =>
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive),
        statusBarKept => SystemChrome.setEnabledSystemUIMode(
            SystemUiMode.manual,
            overlays: const [SystemUiOverlay.top],
          ),
      };
}

/// How long bars the user revealed stay up before the app hides them again,
/// about as long as the system keeps sticky ones up.
const kRevealedSystemBarsHideDelay = Duration(seconds: 3);
