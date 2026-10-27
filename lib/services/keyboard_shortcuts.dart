import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/platform/host_platform.dart';

/// What a desktop keyboard shortcut asks of the screen on top (NAV-014).
sealed class KeyboardShortcut {
  const KeyboardShortcut();

  /// The shortcut [event] presses with [keyboard]'s modifiers, or null. While
  /// [editingText], a key the text field moves its caret with is the field's.
  static KeyboardShortcut? of(
    KeyEvent event, {
    required HardwareKeyboard keyboard,
    required bool mac,
    required bool editingText,
  }) {
    for (final (key, shortcut) in keys(mac: mac)) {
      if (key.accepts(event, keyboard)) {
        return editingText && _movesCaret(key) ? null : shortcut;
      }
    }
    return null;
  }

  /// Command-Left and -Right take a Mac text field's caret to the line's
  /// ends, so Safari leaves them to the field and goes back only outside it.
  static bool _movesCaret(SingleActivator key) =>
      key.meta &&
      (key.trigger == LogicalKeyboardKey.arrowLeft ||
          key.trigger == LogicalKeyboardKey.arrowRight);

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
      // or Command-Left there, as in Safari.
      if (mac) ...[
        (command(LogicalKeyboardKey.bracketLeft), const GoBack()),
        (command(LogicalKeyboardKey.bracketRight), const GoForward()),
        (command(LogicalKeyboardKey.arrowLeft), const GoBack()),
        (command(LogicalKeyboardKey.arrowRight), const GoForward()),
      ] else ...[
        (plain(LogicalKeyboardKey.arrowLeft, alt: true), const GoBack()),
        (plain(LogicalKeyboardKey.arrowRight, alt: true), const GoForward()),
      ],
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

  /// The first key that asks for a shortcut of type [T], the one a menu
  /// names beside it.
  static SingleActivator? keyFor<T extends KeyboardShortcut>({
    required bool mac,
  }) => keys(mac: mac).where((entry) => entry.$2 is T).firstOrNull?.$1;

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

  /// Whether a locked kiosk session keeps it: reload and in-page back and
  /// forward stay on the site, the rest reach its tabs, its address or other
  /// sites (KIOSK-002).
  bool get keptInKiosk => switch (this) {
    ReloadPage() || GoBack() || GoForward() => true,
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

/// One step forward in the page's history, where it has one.
final class GoForward extends KeyboardShortcut {
  const GoForward();
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

/// A screen that answers keyboard shortcuts while it is the route on top.
abstract interface class ShortcutScreen {
  /// Whether the screen is the route on top: a dialog, a sheet, a menu or a
  /// screen over it keeps the keys.
  bool get onTop;

  /// Runs [shortcut], and says whether it did; false leaves the key to the
  /// focused widget.
  bool answerShortcut(KeyboardShortcut shortcut);
}

/// The desktop keys for [ShortcutScreen]. A key reaches them before the
/// focused widget: Linux's webview keeps every key it is given, so asked
/// after it they would never run. A key the screen has nothing to do with now
/// goes on to the focused widget, the page's own select all among them.
final class KeyboardShortcuts {
  KeyboardShortcuts(this._screen);

  final ShortcutScreen _screen;

  void start() {
    if (hostIsDesktop) FocusManager.instance.addEarlyKeyEventHandler(_onKey);
  }

  void dispose() => FocusManager.instance.removeEarlyKeyEventHandler(_onKey);

  /// Whether one of the app's own text fields has the keys, the URL bar's or
  /// the find bar's. A page's field is the webview's to answer for.
  @visibleForTesting
  static bool get editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  KeyEventResult _onKey(KeyEvent event) {
    final shortcut = KeyboardShortcut.of(
      event,
      keyboard: HardwareKeyboard.instance,
      mac: hostIsMacOS,
      editingText: editingText,
    );
    if (shortcut == null || !_screen.onTop) return KeyEventResult.ignored;
    return _screen.answerShortcut(shortcut)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }
}
