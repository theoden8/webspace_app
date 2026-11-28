import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/channel_reply.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/services/log_service.dart';

/// One item of the Site menu: the shortcut it runs, its name and the key it
/// writes beside it.
typedef ShortcutMenuLine = ({
  KeyboardShortcut shortcut,
  Localized title,
  SingleActivator key,
});

/// What the Site menu holds: its name in the menu bar and its items.
typedef ShortcutMenuContent = ({Localized title, List<ShortcutMenuLine> lines});

/// The Site menu the macOS runner adds to the menu bar beside the stock Edit
/// and View menus, which lists the keyboard shortcuts (A11Y-012). Flutter's
/// `PlatformMenuBar` would replace the whole menu bar, Edit menu included,
/// and WKWebView takes Cut, Copy, Paste, Undo and Select All from that menu.
///
/// A press comes back by the item's place in what was last sent, and runs as
/// its key does ([KeyboardShortcuts.press]). The items write their keys but
/// the runner answers none of them, so a key goes on reaching the app as it
/// did and runs once.
final class ShortcutMenu {
  ShortcutMenu({bool? offered}) : offered = offered ?? hostIsMacOS;

  static final instance = ShortcutMenu();

  static const _channel = MethodChannel(
    'org.codeberg.theoden8.webspace/shortcut_menu',
  );

  /// Whether the runner has a menu bar to add it to: macOS alone.
  final bool offered;

  List<KeyboardShortcut> _shown = const [];
  String? _sent;

  /// One item per shortcut [KeyConvention.mac] binds, at the first key that
  /// asks for it, in the order the keys are declared; while a kiosk is
  /// locked, only those it keeps (KIOSK-002).
  static ShortcutMenuContent contentOf(
    AppLocalizations loc, {
    required bool kioskLocked,
  }) {
    final listed = <KeyboardShortcut>{};
    return (
      title: loc.shortcutMenuTitle,
      lines: [
        for (final (key, shortcut) in KeyboardShortcut.keys(
          on: KeyConvention.mac,
        ))
          if ((!kioskLocked || shortcut.keptInKiosk) && listed.add(shortcut))
            (shortcut: shortcut, title: shortcut.menuTitle(loc), key: key),
      ],
    );
  }

  /// Puts [content] in the menu bar, an empty menu taking it out. The same
  /// content again sends nothing.
  void show(ShortcutMenuContent content) {
    if (!offered) return;
    final args = {
      'title': content.title,
      'items': [
        for (final (id, line) in content.lines.indexed) _item(line, id: id),
      ],
    };
    final text = jsonEncode(args);
    if (text == _sent) return;
    _sent = text;
    _shown = [for (final line in content.lines) line.shortcut];
    _channel.setMethodCallHandler(_answer);
    unawaited(_invoke('show', args: args));
  }

  static Map<String, Object> _item(ShortcutMenuLine line, {required int id}) {
    final key = line.key;
    final equivalent = keyEquivalent(key.trigger);
    assert(equivalent != null, 'the Site menu writes every key: ${key.trigger}');
    return {
      'id': id,
      'title': line.title,
      'key': equivalent ?? '',
      'command': key.meta,
      'shift': key.shift,
      'option': key.alt,
      'control': key.control,
    };
  }

  /// [key] as an `NSMenuItem`'s key equivalent: its character, or the
  /// private-use character AppKit names a function key by (`NSEvent.h`).
  static String? keyEquivalent(LogicalKeyboardKey key) {
    if (_named[key] case final named?) return named;
    final label = key.keyLabel;
    return label.runes.length == 1 ? label.toLowerCase() : null;
  }

  static final _named = {
    LogicalKeyboardKey.tab: '\t',
    LogicalKeyboardKey.arrowLeft: '\u{F702}',
    LogicalKeyboardKey.arrowRight: '\u{F703}',
    LogicalKeyboardKey.f5: '\u{F708}',
    LogicalKeyboardKey.f6: '\u{F709}',
    LogicalKeyboardKey.pageUp: '\u{F72C}',
    LogicalKeyboardKey.pageDown: '\u{F72D}',
  };

  Future<Object?> _answer(MethodCall call) async {
    switch (call.method) {
      case 'pressed':
        if (call.arguments case {'id': final int id}
            when id >= 0 && id < _shown.length) {
          KeyboardShortcuts.press(_shown[id]);
        }
      default:
        throw MissingPluginException('shortcut_menu: no ${call.method}');
    }
    return null;
  }

  Future<void> _invoke(String method, {required Object? args}) async {
    switch (await _channel.ask<void>(method, arguments: args)) {
      case Answered():
        break;
      case PlatformRefused(:final error):
        LogTag.navigation.error('Site menu $method failed: ${error.code}');
      case NoPlugin():
        LogTag.navigation.warning('Site menu $method: the runner has no channel');
    }
  }
}
