import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/hint_button.dart';

/// A settings title with its hint button beside it. The label is `Flexible`,
/// so a long translation wraps instead of overflowing the row (HINT-001).
///
/// [hint] is required but nullable: every row decides whether it needs one.
class HintedTitle extends StatelessWidget {
  const HintedTitle(
    this.title, {
    super.key,
    required this.hint,
    this.hintTitle,
    this.style,
    this.warn = false,
  });

  final String title;
  final String? hint;

  /// The dialog's title, when it should name more than the row does.
  final String? hintTitle;
  final TextStyle? style;

  /// Marks a setting that is on while the data it needs is missing.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final hint = this.hint;
    if (hint == null && !warn) return Text(title, style: style);
    return Row(
      children: [
        Flexible(child: Text(title, style: style)),
        if (hint != null)
          HintButton(title: hintTitle ?? title, description: hint),
        if (warn) const MissingDataIcon(),
      ],
    );
  }
}

/// Persistent counterpart of the "not configured" SnackBar: the gap stays
/// visible after the SnackBar is gone.
class MissingDataIcon extends StatelessWidget {
  const MissingDataIcon({super.key});

  static const Color color = Colors.orange;

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: Spacing.xs),
    child: Icon(Icons.warning_amber_rounded, size: 18, color: color),
  );
}

/// Why a row cannot be changed here. The row renders disabled; the reason, if
/// any, takes the subtitle's place.
sealed class Lock {
  const Lock([this._text]);

  final String? _text;

  String? reason(AppLocalizations loc) => _text;
}

/// Tracking Protection holds the setting at [forcedTo]. Forcing on needs no
/// note, a greyed-on switch says it; taking something away does.
final class TrackingProtectionLock extends Lock {
  const TrackingProtectionLock({required this.forcedTo});

  final bool forcedTo;

  @override
  String? reason(AppLocalizations loc) =>
      forcedTo ? null : loc.siteSettingsForcedOffByTrackingProtection;
}

/// The archive the site is in decides the setting (ARCH-006).
final class ArchiveLock extends Lock {
  const ArchiveLock();

  @override
  String reason(AppLocalizations loc) => loc.settingLockedByArchive;
}

/// An app-wide setting already covers every site.
final class AppWideLock extends Lock {
  const AppWideLock(String super.text);
}

/// The setting cannot act until data is downloaded.
final class NotDownloadedLock extends Lock {
  const NotDownloadedLock(String super.text);
}

/// The platform or engine cannot honour the setting.
final class PlatformLock extends Lock {
  const PlatformLock(String super.text);
}

/// Another setting decides this one while it is on. Without a reason when the
/// deciding row sits right above.
final class RequiresLock extends Lock {
  const RequiresLock([super.text]);
}

/// What sits at the trailing end of a row and what tapping it does.
sealed class SettingControl {
  const SettingControl();
}

final class Toggle extends SettingControl {
  const Toggle(this.value, this.onChanged);

  final bool value;
  final ValueChanged<bool> onChanged;
}

/// A switch bound to an app pref: shows its live value and sets it.
final class PrefToggle extends SettingControl {
  const PrefToggle(this.pref);

  final AppPref<bool> pref;
}

/// Opens a screen or a picker; drawn with a chevron.
final class Opens extends SettingControl {
  const Opens(this.onTap);

  final VoidCallback onTap;
}

final class Trailing extends SettingControl {
  const Trailing(this.child, {this.onTap});

  final Widget? child;
  final VoidCallback? onTap;
}

/// One settings row: title + hint, an optional state subtitle, and a control.
///
/// A [lock] disables the control and puts its reason in the subtitle slot.
/// [missingData] is for a setting that is on but has nothing to act with yet:
/// it marks the title and turns the subtitle amber.
class SettingTile extends StatelessWidget {
  const SettingTile({
    super.key,
    required this.title,
    required this.hint,
    this.hintTitle,
    this.leading,
    this.subtitle,
    this.control,
    this.lock,
    this.missingData = false,
    this.contentPadding,
  });

  final String title;
  final String? hint;
  final String? hintTitle;
  final Widget? leading;
  final String? subtitle;
  final SettingControl? control;
  final Lock? lock;
  final bool missingData;
  final EdgeInsetsGeometry? contentPadding;

  static const double chevronSize = 18;

  @override
  Widget build(BuildContext context) {
    final locked = lock != null;
    final text = lock?.reason(AppLocalizations.of(context)) ?? subtitle;
    final titleRow = HintedTitle(
      title,
      hint: hint,
      hintTitle: hintTitle,
      warn: missingData,
    );
    final subtitleText = text == null
        ? null
        : Text(
            text,
            style: missingData
                ? const TextStyle(color: MissingDataIcon.color)
                : null,
          );
    Widget toggle(bool value, ValueChanged<bool> onChanged) => SwitchListTile(
      secondary: leading,
      contentPadding: contentPadding,
      title: titleRow,
      subtitle: subtitleText,
      value: value,
      onChanged: locked ? null : onChanged,
    );
    if (control case Toggle(:final value, :final onChanged)) {
      return toggle(value, onChanged);
    }
    if (control case PrefToggle(:final pref)) {
      return ValueListenableBuilder<bool>(
        valueListenable: pref.listenable,
        builder: (context, value, _) => toggle(value, pref.set),
      );
    }
    final (Widget? trailing, VoidCallback? onTap) = switch (control) {
      Opens(:final onTap) => (
        const Icon(Icons.chevron_right, size: chevronSize),
        onTap,
      ),
      Trailing(:final child, :final onTap) => (child, onTap),
      Toggle() || PrefToggle() || null => (null, null),
    };
    return ListTile(
      leading: leading,
      contentPadding: contentPadding,
      enabled: !locked,
      title: titleRow,
      subtitle: subtitleText,
      trailing: trailing == null
          ? null
          : IgnorePointer(ignoring: locked, child: trailing),
      onTap: onTap,
    );
  }
}

/// A row that picks one of [values] from a dropdown. Re-picking the shown
/// value is not a change.
class ChoiceTile<T extends Object> extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.title,
    required this.hint,
    this.hintTitle,
    this.subtitle,
    required this.values,
    required this.label,
    required this.value,
    required this.onChanged,
    this.offered,
    this.lock,
  });

  final String title;
  final String? hint;
  final String? hintTitle;
  final String? subtitle;
  final List<T> values;
  final String Function(T value) label;
  final T value;
  final ValueChanged<T> onChanged;

  /// Values shown but not pickable here; all are when null.
  final bool Function(T value)? offered;
  final Lock? lock;

  /// Keeps a long label (Greek runs to 32 characters) from squeezing the
  /// title; the open menu is wider and shows it whole.
  static const double maxWidth = 160;
  static const double menuWidth = 280;

  @override
  Widget build(BuildContext context) => SettingTile(
    title: title,
    hint: hint,
    hintTitle: hintTitle,
    subtitle: subtitle,
    lock: lock,
    control: Trailing(
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          menuWidth: menuWidth,
          onChanged: (next) {
            if (next != null && next != value) onChanged(next);
          },
          selectedItemBuilder: (context) => [
            for (final v in values)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Text(
                  label(v),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          items: [
            for (final v in values)
              DropdownMenuItem(
                value: v,
                enabled: offered?.call(v) ?? true,
                child: Text(label(v)),
              ),
          ],
        ),
      ),
    ),
  );
}

/// The names of what is on, the first two and a count of the rest; [none]
/// when nothing is. The subtitle rule of every [SummaryNavRow] that lists
/// what its screen has on (BEHAV-002).
String summariseSettings(
  AppLocalizations loc,
  List<String> on, {
  required String none,
}) {
  if (on.isEmpty) return none;
  const shown = 2;
  const separator = ' · ';
  final overflow = on.length - shown;
  return [
    ...on.take(shown),
    if (overflow > 0) loc.permissionsSummaryMore(overflow),
  ].join(separator);
}

/// A row that opens a screen of related settings. Its subtitle says what is
/// set there, so the common question is answered without opening it.
class SummaryNavRow extends StatelessWidget {
  const SummaryNavRow({
    super.key,
    required this.leading,
    required this.title,
    required this.summary,
    required this.onTap,
    this.marks = const [],
  });

  final Widget leading;
  final String title;
  final String? summary;
  final VoidCallback onTap;

  /// Shown before the chevron.
  final List<Widget> marks;

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    return ListTile(
      leading: leading,
      title: Text(title),
      subtitle: summary == null
          ? null
          : Text(summary, style: const TextStyle(fontSize: 12.5)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...marks,
          const Icon(Icons.chevron_right, size: SettingTile.chevronSize),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A [ChoiceTile] over an enum, whose [ChoiceTile.label] is usually a
/// `switch` extension so a new value does not compile until it has a name.
typedef EnumTile<T extends Enum> = ChoiceTile<T>;

/// Label above a group of rows, optionally with a hint and a trailing action.
class SettingsSection extends StatelessWidget {
  const SettingsSection(this.title, {super.key, this.hint, this.trailing});

  final String title;
  final String? hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = HintedTitle(
      title,
      hint: hint,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.lg,
        20,
        trailing == null ? Spacing.lg : Spacing.sm,
        6,
      ),
      child: trailing == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}

/// Small print under a group: the site a screen edits, or a note on the rows
/// above it.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.padding = defaultPadding});

  /// The site a per-site screen edits, right under its app bar.
  const SettingsNote.host(this.text, {super.key})
    : padding = const EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.md,
      );

  static const EdgeInsets defaultPadding = EdgeInsets.fromLTRB(
    Spacing.lg,
    Spacing.xs,
    Spacing.lg,
    Spacing.sm,
  );

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
