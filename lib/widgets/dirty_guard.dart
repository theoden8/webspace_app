import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/widgets/confirm_dialog.dart';

/// Asks before a pop would drop unsaved edits (EDIT-009, BUG-006).
///
/// [snapshot] returns every value a save would store as one record. Records
/// compare field by field, so a value is guarded exactly when it is in the
/// record; a collection goes in as a [ValueList] or [ValueSet], which compare
/// by element where a List or Set would compare by identity.
mixin DirtyGuard<W extends StatefulWidget> on State<W> {
  Record snapshot();

  late Record _clean;

  /// Takes the form as it stands as the saved one: once it is loaded, and
  /// after each save.
  void markClean() => _clean = snapshot();

  bool get isDirty => snapshot() != _clean;

  /// Held while the discard prompt is up, so a second back press does not
  /// stack a second prompt over it.
  final _asking = ReentryGuard();

  /// The screen, with system back and app-bar back asking first while dirty.
  /// Text fields must rebuild the screen as they change, so the answer is
  /// current when back is pressed.
  Widget guardPop({required Widget child}) => PopScope(
        canPop: !isDirty,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          await _asking.run(() async {
            final loc = AppLocalizations.of(context);
            final discard = await confirm(
              context,
              title: loc.siteSettingsDiscardDialogTitle,
              body: loc.siteSettingsDiscardDialogBody,
              cancelLabel: loc.siteSettingsDiscardKeepEditing,
              confirmLabel: loc.siteSettingsDiscardConfirm,
              destructive: true,
            );
            if (discard) await popClean();
          });
        },
        child: child,
      );

  /// Leaves without asking, as a save does; false when the screen was gone
  /// or covered first. The pop waits a frame so the rebuild commits the
  /// clean `canPop`.
  Future<bool> popClean<T extends Object?>([T? result]) async {
    if (!mounted) return false;
    setState(markClean);
    await WidgetsBinding.instance.endOfFrame;
    // A pop with another route on top would close that one instead.
    if (!mounted || ModalRoute.isCurrentOf(context) != true) return false;
    Navigator.of(context).pop(result);
    return true;
  }
}

/// A list that compares by its elements, for a [DirtyGuard] snapshot.
@immutable
final class ValueList<T> {
  ValueList(Iterable<T> items) : _items = List.unmodifiable(items);

  final List<T> _items;

  @override
  bool operator ==(Object other) =>
      other is ValueList<T> && listEquals(other._items, _items);

  @override
  int get hashCode => Object.hashAll(_items);
}

/// A set that compares by its elements, for a [DirtyGuard] snapshot.
@immutable
final class ValueSet<T> {
  ValueSet(Iterable<T> items) : _items = Set.unmodifiable(items);

  final Set<T> _items;

  @override
  bool operator ==(Object other) =>
      other is ValueSet<T> && setEquals(other._items, _items);

  @override
  int get hashCode => Object.hashAllUnordered(_items);
}
