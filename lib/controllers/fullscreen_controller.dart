import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/fullscreen_system_ui.dart';
import 'package:webspace/settings/app_prefs.dart';

/// What full screen asks of the page.
abstract interface class FullscreenHost implements PageHost {
  bool get kioskLocked;
}

/// Full screen (FS-*): whether the page is in it, the system UI mode it
/// holds, and the tab strip the tab-bar button reveals.
class FullscreenController {
  FullscreenController({
    required FullscreenHost host,
    required SurfaceRepaintController surface,
  })  : _host = host,
        _surface = surface;

  final FullscreenHost _host;
  final SurfaceRepaintController _surface;

  /// Hides the app bar, the tab strip and the system UI.
  bool active = false;

  /// Whether the tab-bar button has revealed the tab strip (FS-009). Runtime
  /// only. A site switch out of full screen keeps it; its dismiss control,
  /// full screen and an app entry point end it.
  bool get tabStripRevealed => _tabStripRevealed;
  bool _tabStripRevealed = false;

  Timer? _revealedBarsHideTimer;

  void start() {
    AppPref.tabStripInFullscreen.listenable.addListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.addListener(_onTabStripPrefChanged);
    // Only Android's embedder implements the listener; elsewhere registering
    // it throws MissingPluginException.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(SystemChrome.setSystemUIChangeCallback(onSystemUiChange));
    }
  }

  void dispose() {
    _revealedBarsHideTimer?.cancel();
    AppPref.tabStripInFullscreen.listenable
        .removeListener(_onTabStripPrefChanged);
    AppPref.tabBarButton.listenable.removeListener(_onTabStripPrefChanged);
    unawaited(SystemChrome.setSystemUIChangeCallback(null));
  }

  void _onTabStripPrefChanged() {
    if (!AppPref.tabBarButton.value) hideTabStrip();
    if (active) apply();
  }

  void revealTabStrip() {
    if (_tabStripRevealed) return;
    _tabStripRevealed = true;
    _host.rebuild();
    _surface.nudge('tab-overlay-show');
  }

  void hideTabStrip() {
    if (!_tabStripRevealed) return;
    _tabStripRevealed = false;
    _host.rebuild();
    _surface.nudge('tab-overlay-hide');
  }

  void enter() {
    if (active) {
      // The mode depends on the kiosk lock and the tab strip prefs, which a
      // shortcut launch or an import can change while already full screen.
      apply();
      // A site or tab landing in full screen: there a revealed strip lasts
      // one pick.
      hideTabStrip();
      return;
    }
    active = true;
    _tabStripRevealed = false;
    _host.rebuild();
    apply();
    // Removing the app bar / changing the bottom bar resizes the webview; on
    // Android the hybrid-composition SurfaceView can come back with a 1px dark
    // seam at the bottom edge until it recomposites. github #421-followup
    _surface.nudge('fullscreen-toggle');
    // KIOSK-003: the hint promises an exit that a locked session won't honor.
    if (_host.kioskLocked) return;
    _host.toast((loc) => loc.homeExitFullscreenHint,
        duration: const Duration(seconds: 2), floating: true);
  }

  void exit() {
    // KIOSK-003: a locked kiosk session stays fullscreen; the only exit is to
    // relaunch the app normally (which clears the lock).
    if (_host.kioskLocked) return;
    if (!active) return;
    _revealedBarsHideTimer?.cancel();
    active = false;
    _tabStripRevealed = false;
    _host.rebuild();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _surface.nudge('fullscreen-exit');
  }

  void toggle() {
    if (active) {
      exit();
    } else {
      enter();
    }
  }

  SystemUiMode get _systemUiMode => fullscreenSystemUiMode(
        tabStripInFullscreen: AppPref.tabStripInFullscreen.value,
        tabBarButton: AppPref.tabBarButton.value,
        kioskLocked: _host.kioskLocked,
      );

  /// Sets the system UI mode full screen holds now.
  void apply() {
    unawaited(SystemChrome.setEnabledSystemUIMode(_systemUiMode));
  }

  /// Under `immersive` (FS-011) a bar the user swipes in stays until the app
  /// hides it; the body and the tab strip inset around it meanwhile.
  Future<void> onSystemUiChange(bool systemOverlaysAreVisible) async {
    _revealedBarsHideTimer?.cancel();
    if (!_host.mounted || !active) return;
    if (_systemUiMode != SystemUiMode.immersive) return;
    _surface.nudge('system-bars');
    if (!systemOverlaysAreVisible) return;
    _revealedBarsHideTimer = Timer(kRevealedSystemBarsHideDelay, () {
      if (_host.mounted && active) apply();
    });
  }
}
