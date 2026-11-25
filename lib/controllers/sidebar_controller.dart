import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_navigation.dart';

/// The one owner of the sidebar's state, one for the app and remembered
/// across restarts in [AppPref.sidebarState], and of a phone's drawer over
/// the page: what each control asks of them. On a phone open and collapsed
/// both show the rail; the drawer is a runtime flag over them, so a window
/// that narrows and widens again leaves the app-wide state as it was.
class SidebarController extends ChangeNotifier {
  /// The state [hide] left, which [restore] brings back.
  SidebarState? _beforeHidden;

  SidebarState get state => currentSidebarState;

  /// A phone's drawer is open over the page. Runtime only.
  bool get drawerShown => _drawerShown;
  bool _drawerShown = false;

  void _set(SidebarState next) {
    if (next == SidebarState.hidden && state != SidebarState.hidden) {
      _beforeHidden = state;
    }
    if (next == SidebarState.hidden) _showDrawer(shown: false);
    unawaited(AppPref.sidebarState.set(next.name));
  }

  void _showDrawer({required bool shown}) {
    if (_drawerShown == shown) return;
    _drawerShown = shown;
    notifyListeners();
  }

  /// The open sidebar's collapse button: open to the rail.
  void collapse() => _set(SidebarState.collapsed);

  /// The rail's expand button: open on a wide window, the drawer on a phone.
  void expand({required bool wide}) =>
      wide ? _set(SidebarState.open) : _showDrawer(shown: true);

  /// The phone's drawer goes, leaving the rail.
  void closeDrawer() => _showDrawer(shown: false);

  /// The rail's cross.
  void hide() => _set(SidebarState.hidden);

  /// The app bar's sidebar icon: open, never the rail; on a phone the drawer.
  void openFully({required bool wide}) {
    _set(SidebarState.open);
    if (!wide) _showDrawer(shown: true);
  }

  /// The arrow tab's tap: back as it was before it was hidden, and where no
  /// rail docks ([drawer]) the drawer over the page.
  void restore({required bool drawer}) {
    if (state == SidebarState.hidden) {
      _set(_beforeHidden ?? SidebarState.open);
    }
    if (drawer) _showDrawer(shown: true);
  }

  /// The keyboard shortcut.
  void cycle() => _set(switch (state) {
    SidebarState.open => SidebarState.collapsed,
    SidebarState.collapsed => SidebarState.hidden,
    SidebarState.hidden => SidebarState.open,
  });

  /// Where a drag of the arrow tab let go; let go open on a phone, the
  /// drawer.
  void settle(SidebarState to, {required bool wide}) {
    _set(to);
    if (!wide && to == SidebarState.open) _showDrawer(shown: true);
  }
}
