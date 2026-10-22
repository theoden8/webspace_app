import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/controllers/back_gesture_controller.dart';
import 'package:webspace/controllers/site_reset_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/web_view_model.dart';

/// What a desktop keyboard shortcut asks of the page (NAV-014).
sealed class KeyboardShortcut {
  const KeyboardShortcut();

  /// The shortcut [event] presses with [keyboard]'s modifiers, or null.
  static KeyboardShortcut? of(
    KeyEvent event, {
    required HardwareKeyboard keyboard,
    required bool mac,
  }) {
    for (final (key, shortcut) in keys(mac: mac)) {
      if (key.accepts(event, keyboard)) return shortcut;
    }
    return null;
  }

  /// Every key a shortcut takes, Command on a Mac where elsewhere it is
  /// Control, as the platform's browsers take them. A held key asks once.
  static List<(SingleActivator, KeyboardShortcut)> keys({required bool mac}) {
    SingleActivator command(LogicalKeyboardKey key) =>
        SingleActivator(key, meta: mac, control: !mac, includeRepeats: false);
    SingleActivator plain(
      LogicalKeyboardKey key, {
      bool control = false,
      bool shift = false,
      bool alt = false,
    }) => SingleActivator(
      key,
      control: control,
      shift: shift,
      alt: alt,
      includeRepeats: false,
    );
    return [
      (command(LogicalKeyboardKey.keyT), const OpenNewTab()),
      (command(LogicalKeyboardKey.keyW), const CloseActiveTab()),
      (command(LogicalKeyboardKey.keyL), const FocusUrlBar()),
      (command(LogicalKeyboardKey.keyR), const ReloadPage()),
      (plain(LogicalKeyboardKey.f5), const ReloadPage()),
      (command(LogicalKeyboardKey.keyF), const FindInPage()),
      // Option-Left moves the caret a word on a Mac, so back is Command-[
      // there, as in Safari.
      if (mac)
        (command(LogicalKeyboardKey.bracketLeft), const GoBack())
      else
        (plain(LogicalKeyboardKey.arrowLeft, alt: true), const GoBack()),
      (plain(LogicalKeyboardKey.tab, control: true), const NextSite()),
      (
        plain(LogicalKeyboardKey.tab, control: true, shift: true),
        const PreviousSite(),
      ),
      if (!mac) ...[
        (command(LogicalKeyboardKey.pageDown), const NextSite()),
        (command(LogicalKeyboardKey.pageUp), const PreviousSite()),
      ],
      for (final (place, digit) in _placeDigits.indexed)
        (command(digit), SiteAt(place)),
      (command(LogicalKeyboardKey.digit9), const LastSite()),
    ];
  }

  static const _placeDigits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  ];

  /// Whether a locked kiosk session keeps it: reload and in-page back stay
  /// on the site, the rest reach its tabs, its address or other sites
  /// (KIOSK-002).
  bool get keptInKiosk => switch (this) {
    ReloadPage() || GoBack() => true,
    OpenNewTab() ||
    CloseActiveTab() ||
    FocusUrlBar() ||
    FindInPage() ||
    NextSite() ||
    PreviousSite() ||
    SiteAt() ||
    LastSite() => false,
  };
}

/// The site menu's New tab (TAB-005).
final class OpenNewTab extends KeyboardShortcut {
  const OpenNewTab();
}

/// The Tabs sheet's close, on the tab on screen (TAB-007).
final class CloseActiveTab extends KeyboardShortcut {
  const CloseActiveTab();
}

final class FocusUrlBar extends KeyboardShortcut {
  const FocusUrlBar();
}

/// The site menu's Refresh.
final class ReloadPage extends KeyboardShortcut {
  const ReloadPage();
}

/// The site menu's Find in page.
final class FindInPage extends KeyboardShortcut {
  const FindInPage();
}

/// The site menu's Back.
final class GoBack extends KeyboardShortcut {
  const GoBack();
}

/// The next site along the tab strip, round to the first.
final class NextSite extends KeyboardShortcut {
  const NextSite();
}

final class PreviousSite extends KeyboardShortcut {
  const PreviousSite();
}

/// The site at [place] along the tab strip, counted from 0.
final class SiteAt extends KeyboardShortcut {
  const SiteAt(this.place);

  final int place;
}

final class LastSite extends KeyboardShortcut {
  const LastSite();
}

/// What the page answers for a keyboard shortcut beyond the controllers that
/// own tabs, reloads and back.
abstract interface class KeyboardShortcutHost {
  bool get mounted;
  bool get kioskLocked;

  /// Whether the page is the route on top: a dialog, a sheet, a menu or a
  /// screen over it keeps the keys.
  bool get onTop;

  /// Puts the cursor in the URL bar with the address selected; false where
  /// no URL bar is on screen.
  bool focusUrlBar();

  /// The site menu's Find in page; false where the find bar cannot show.
  bool findInPage();

  /// What a tap on [site] in the tab strip does.
  Future<void> openSite(WebViewModel site);
}

/// The page's desktop keyboard shortcuts (NAV-014). A key reaches them before
/// the focused widget: Linux's webview keeps every key it is given, so asked
/// after it they would never run. A key the page has nothing to do with now
/// goes on to the focused widget, the page's own select all among them.
class KeyboardShortcutController {
  KeyboardShortcutController(
    this._sites, {
    required KeyboardShortcutHost host,
    required TabsController tabs,
    required SiteResetController resets,
    required BackGestureController back,
  }) : _host = host,
       _tabs = tabs,
       _resets = resets,
       _back = back;

  final SiteRuntime _sites;
  final KeyboardShortcutHost _host;
  final TabsController _tabs;
  final SiteResetController _resets;
  final BackGestureController _back;

  void start() {
    if (hostIsDesktop) FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  void dispose() => FocusManager.instance.removeEarlyKeyEventHandler(_onKey);

  KeyEventResult _onKey(KeyEvent event) {
    final shortcut = KeyboardShortcut.of(
      event,
      keyboard: HardwareKeyboard.instance,
      mac: hostIsMacOS,
    );
    if (shortcut == null) return KeyEventResult.ignored;
    return answer(shortcut) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Runs [shortcut] for the site on screen, and says whether it did.
  bool answer(KeyboardShortcut shortcut) {
    final site = _sites.shown;
    if (site == null || !_host.mounted || !_host.onTop) return false;
    if (_host.kioskLocked && !shortcut.keptInKiosk) return false;
    return switch (shortcut) {
      OpenNewTab() => _run(_tabs.forShownSite(_tabs.newTab)),
      CloseActiveTab() => _run(
        _tabs.forShownSite(
          (shown) => _tabs.closeTab(shown, tabId: shown.activeTabId),
        ),
      ),
      FocusUrlBar() => _host.focusUrlBar(),
      ReloadPage() => _run(() => unawaited(_resets.refreshShown())),
      FindInPage() => _host.findInPage(),
      GoBack() => _run(() => unawaited(_back.goBackIfPossible())),
      NextSite() => _step(site, by: 1),
      PreviousSite() => _step(site, by: -1),
      SiteAt(:final place) => _openAt(place),
      LastSite() => _openAt(_strip.length - 1),
    };
  }

  static bool _run(void Function()? act) {
    if (act == null) return false;
    act();
    return true;
  }

  List<WebViewModel> get _strip => [
    for (final i in _sites.filteredIndices()) _sites.models[i],
  ];

  bool _step(WebViewModel site, {required int by}) {
    final strip = _strip;
    if (strip.isEmpty) return false;
    final at = strip.indexOf(site);
    final to = at < 0 ? (by > 0 ? 0 : strip.length - 1) : at + by;
    return _openAt(to % strip.length);
  }

  bool _openAt(int place) {
    final strip = _strip;
    if (place < 0 || place >= strip.length) return false;
    final site = strip[place];
    if (!identical(site, _sites.shown)) unawaited(_host.openSite(site));
    return true;
  }
}
