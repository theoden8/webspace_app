import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/keyboard_input.dart';

/// Whose keys the shortcuts take, as the platform's browsers take them
/// (NAV-014).
enum KeyConvention {
  /// Command where the others take Control.
  mac,

  /// Control, on Linux and Windows.
  pc,

  /// Control, as Chrome takes it with a keyboard attached (NAV-019).
  android;

  /// The host's, or null where the app takes no keys of its own: iOS and the
  /// web. A platform override, which only a test sets, picks the keys too, as
  /// it picks Flutter's own text field shortcuts.
  static KeyConvention? get host {
    switch (debugDefaultTargetPlatformOverride) {
      case TargetPlatform.macOS:
        return mac;
      case TargetPlatform.linux || TargetPlatform.windows:
        return pc;
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS || TargetPlatform.fuchsia:
        return null;
      case null:
        break;
    }
    if (hostIsMacOS) return mac;
    if (hostIsAndroid) return android;
    if (hostIsDesktop) return pc;
    return null;
  }

  /// Whether a key leaves the app. Command-Q is the Mac menu's, which AppKit
  /// runs before any view, and an Android app does not quit itself.
  bool get quits => switch (this) {
    pc => true,
    mac || android => false,
  };

  /// The modifier a click holds to open a link in a new tab, as a page's
  /// MouseEvent names it: Command on a Mac, Control elsewhere (TAB-029).
  String get newTabClickKey => switch (this) {
    mac => 'metaKey',
    pc || android => 'ctrlKey',
  };

  /// Whether menus write a shortcut's key beside the item it runs: on
  /// Android only while a keyboard is attached, which it may never be.
  bool get writesKeys => switch (this) {
    mac || pc => true,
    android => KeyboardInput.attached.value,
  };
}

/// What a keyboard shortcut asks of the screen on top (NAV-014).
sealed class KeyboardShortcut {
  const KeyboardShortcut();

  /// The shortcut [event] presses with [keyboard]'s modifiers, or null. While
  /// [editingText], a key the text field moves its caret with is the field's.
  static KeyboardShortcut? of(
    KeyEvent event, {
    required HardwareKeyboard keyboard,
    required KeyConvention on,
    required bool editingText,
  }) {
    for (final (key, shortcut) in keys(on: on)) {
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

  /// Every key a shortcut takes [on] a platform. A held key asks once.
  static List<(SingleActivator, KeyboardShortcut)> keys({
    required KeyConvention on,
  }) {
    final mac = on == KeyConvention.mac;
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
      (
        SingleActivator(LogicalKeyboardKey.keyT,
            meta: mac, control: !mac, shift: true, includeRepeats: false),
        const ReopenClosedTab(),
      ),
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
      // F6 moves between a browser's address bar and its page in Chrome and
      // Firefox alike.
      (plain(LogicalKeyboardKey.f6), const LeavePage()),
      if (on.quits) (command(LogicalKeyboardKey.keyQ), const QuitApp()),
      // Firefox's key for its sidebar.
      (
        SingleActivator(LogicalKeyboardKey.keyZ,
            meta: mac, control: !mac, alt: true, includeRepeats: false),
        const ToggleSidebar(),
      ),
    ];
  }

  /// The first key that asks for a shortcut of type [T], the one a menu
  /// names beside it.
  static SingleActivator? keyFor<T extends KeyboardShortcut>({
    required KeyConvention on,
  }) => keys(on: on).where((entry) => entry.$2 is T).firstOrNull?.$1;

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
    ReopenClosedTab() ||
    CloseActiveTab() ||
    FocusUrlBar() ||
    LeavePage() ||
    FindInPage() ||
    NextSite() ||
    PreviousSite() ||
    SiteAt() ||
    LastSite() ||
    ToggleSidebar() ||
    QuitApp() => false,
  };

  /// Its name in the macOS menu bar's Site menu (A11Y-012).
  Localized menuTitle(AppLocalizations loc) => switch (this) {
    OpenNewTab() => loc.shortcutMenuNewTab,
    ReopenClosedTab() => loc.shortcutMenuReopenClosedTab,
    CloseActiveTab() => loc.shortcutMenuCloseTab,
    FocusUrlBar() => loc.shortcutMenuFocusUrlBar,
    LeavePage() => loc.shortcutMenuLeavePage,
    ReloadPage() => loc.shortcutMenuReload,
    FindInPage() => loc.shortcutMenuFind,
    GoBack() => loc.shortcutMenuBack,
    GoForward() => loc.shortcutMenuForward,
    NextSite() => loc.shortcutMenuNextSite,
    PreviousSite() => loc.shortcutMenuPreviousSite,
    SiteAt(:final place) => loc.shortcutMenuSiteAt(place + 1),
    LastSite() => loc.shortcutMenuLastSite,
    ToggleSidebar() => loc.shortcutMenuToggleSidebar,
    QuitApp() => loc.trayQuitApp,
  };
}

/// The site menu's New tab (TAB-005).
final class OpenNewTab extends KeyboardShortcut {
  const OpenNewTab();
}

/// The site on screen's newest closed tab back, and opened (TAB-022).
final class ReopenClosedTab extends KeyboardShortcut {
  const ReopenClosedTab();
}

/// The Tabs sheet's close, on the tab on screen (TAB-007).
final class CloseActiveTab extends KeyboardShortcut {
  const CloseActiveTab();
}

final class FocusUrlBar extends KeyboardShortcut {
  const FocusUrlBar();
}

/// The keys out of the page, to the URL bar where it is on, else to the
/// first control of the screen around it: Linux's webview keeps Tab
/// (A11Y-012).
final class LeavePage extends KeyboardShortcut {
  const LeavePage();

  /// Moves focus to the control Tab reaches first on the screen around
  /// [context], and says whether it moved: not where that is the page
  /// itself, as in full screen.
  static bool toFirstControl(BuildContext context) {
    final scope = FocusScope.of(context);
    final first = FocusTraversalGroup.of(context)
        .findFirstFocus(scope, ignoreCurrentFocus: true);
    if (first == null || identical(first, scope) || first.hasPrimaryFocus) {
      return false;
    }
    first.requestFocus();
    return true;
  }
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

/// The next site along the site strip, round to the first.
final class NextSite extends KeyboardShortcut {
  const NextSite();
}

final class PreviousSite extends KeyboardShortcut {
  const PreviousSite();
}

/// The site at [place] along the site strip, counted from 0.
final class SiteAt extends KeyboardShortcut {
  const SiteAt(this.place);

  final int place;

  @override
  bool operator ==(Object other) => other is SiteAt && other.place == place;

  @override
  int get hashCode => Object.hash(SiteAt, place);
}

final class LastSite extends KeyboardShortcut {
  const LastSite();
}

/// Cycles the tab sidebar open, collapsed and hidden.
final class ToggleSidebar extends KeyboardShortcut {
  const ToggleSidebar();
}

/// Leaves the app, where closing its window may only hide it (NOTIF-018).
final class QuitApp extends KeyboardShortcut {
  const QuitApp();
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

/// The keys for [ShortcutScreen]. A key reaches them before the focused
/// widget: Linux's webview keeps every key it is given, and so does a page on
/// Android (NAV-019), so asked after it they would never run. A key the screen
/// has nothing to do with now goes on to the focused widget, the page's own
/// select all among them.
final class KeyboardShortcuts {
  KeyboardShortcuts(this._screen) : _on = KeyConvention.host;

  final ShortcutScreen _screen;
  final KeyConvention? _on;

  /// Every screen that takes the keys now, the last started last.
  static final _started = <KeyboardShortcuts>[];

  void start() {
    if (_on == null) return;
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    _started.add(this);
  }

  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    _started.remove(this);
  }

  /// Runs [shortcut] as its key does, for the screen on top: a press in the
  /// macOS menu bar's Site menu (A11Y-012). Says whether a screen ran it.
  static bool press(KeyboardShortcut shortcut) =>
      _started.reversed.any((keys) => keys._answer(shortcut));

  bool _answer(KeyboardShortcut shortcut) =>
      _screen.onTop && _screen.answerShortcut(shortcut);

  /// Whether one of the app's own text fields has the keys, the URL bar's or
  /// the find bar's. A page's field is the webview's to answer for.
  @visibleForTesting
  static bool get editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  KeyEventResult _onKey(KeyEvent event) {
    final on = _on;
    if (on == null) return KeyEventResult.ignored;
    final shortcut = KeyboardShortcut.of(
      event,
      keyboard: HardwareKeyboard.instance,
      on: on,
      editingText: editingText,
    );
    if (shortcut == null) return KeyEventResult.ignored;
    return _answer(shortcut) ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}
