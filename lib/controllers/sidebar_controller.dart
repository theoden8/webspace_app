import 'dart:async';

import 'package:webspace/services/navigation_surface_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_navigation.dart';

/// The one owner of the sidebar's state, one for the app and remembered
/// across restarts in [AppPref.sidebarState]: what each control asks of it.
class SidebarController {
  /// The state [hide] left, which [restore] brings back.
  SidebarState? _beforeHidden;

  SidebarState get state => currentSidebarState;

  void _set(SidebarState next) {
    if (next == SidebarState.hidden && state != SidebarState.hidden) {
      _beforeHidden = state;
    }
    unawaited(AppPref.sidebarState.set(next.name));
  }

  /// The collapse button: open to the rail.
  void collapse() => _set(SidebarState.collapsed);

  /// The rail's expand button.
  void expand() => _set(SidebarState.open);

  /// The rail's cross.
  void hide() => _set(SidebarState.hidden);

  /// The app bar's sidebar icon: open, never the rail.
  void openFully() => _set(SidebarState.open);

  /// The arrow tab's tap: back as it was before it was hidden.
  void restore() => _set(_beforeHidden ?? SidebarState.open);

  /// The keyboard shortcut.
  void cycle() => _set(switch (state) {
        SidebarState.open => SidebarState.collapsed,
        SidebarState.collapsed => SidebarState.hidden,
        SidebarState.hidden => SidebarState.open,
      });

  /// Where a drag of the arrow tab or the edge let go.
  void settle(SidebarState to) => _set(to);

  /// The window narrowed to a phone's.
  void narrowed() => _set(sidebarOnNarrowing(state));
}
