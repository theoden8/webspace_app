import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';

/// The key for a [KeyboardShortcut] of type [T] as a menu writes it beside
/// the item it runs, or null off the desktop (NAV-014).
String? shortcutLabel<T extends KeyboardShortcut>(MaterialLocalizations names) {
  if (!hostIsDesktop) return null;
  final key = KeyboardShortcut.keyFor<T>(mac: hostIsMacOS);
  if (key == null) return null;
  return describeKey(key, names: names, mac: hostIsMacOS);
}

/// [label] as the tooltip of a button that a [KeyboardShortcut] of type [T]
/// also runs, its key on a line of its own on the desktop (NAV-014).
String shortcutTooltip<T extends KeyboardShortcut>(
  String label, {
  required MaterialLocalizations names,
}) => switch (shortcutLabel<T>(names)) {
  final keys? => '$label\n$keys',
  null => label,
};

/// [key] as the platform's menus write one: "⌘T" on a Mac, "Ctrl+T"
/// elsewhere, in [names]' words for the keys that have them.
String describeKey(
  SingleActivator key, {
  required MaterialLocalizations names,
  required bool mac,
}) {
  final trigger = key.trigger;
  final named = {
    LogicalKeyboardKey.arrowLeft: '←',
    LogicalKeyboardKey.arrowRight: '→',
    LogicalKeyboardKey.pageDown: names.keyboardKeyPageDown,
    LogicalKeyboardKey.pageUp: names.keyboardKeyPageUp,
    if (mac) LogicalKeyboardKey.tab: '⇥',
  };
  final keyName = named[trigger] ?? trigger.keyLabel;
  if (mac) {
    return [
      if (key.control) '⌃',
      if (key.alt) '⌥',
      if (key.shift) '⇧',
      if (key.meta) '⌘',
      keyName,
    ].join();
  }
  return [
    if (key.control) names.keyboardKeyControl,
    if (key.alt) names.keyboardKeyAlt,
    if (key.shift) names.keyboardKeyShift,
    if (key.meta) names.keyboardKeyMeta,
    keyName,
  ].join('+');
}

/// A menu item's key, set off from its label.
class ShortcutKeys extends StatelessWidget {
  const ShortcutKeys(this.keys, {super.key});

  final String keys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      keys,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
