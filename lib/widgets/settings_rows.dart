/// Rows shared by App Settings and the category screens it opens.
library;

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/hint_button.dart';

/// A group heading inside a settings screen, styled like the per-site
/// screens' group headings.
class SettingsGroupHeader extends StatelessWidget {
  const SettingsGroupHeader(this.title, {super.key, this.hint});

  final String title;

  /// What the whole group is for, behind a [HintButton] (HINT-001).
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: Theme.of(context).colorScheme.primary,
    );
    final hint = this.hint;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 20, hint == null ? 16 : 4, 6),
      child: hint == null
          ? Text(title, style: style)
          : Row(
              children: [
                Flexible(child: Text(title, style: style)),
                HintButton(title: title, description: hint),
              ],
            ),
    );
  }
}

/// A row that opens a category screen. The subtitle says what the category
/// is set to, so the common question is answered without opening it.
class SettingsCategoryRow extends StatelessWidget {
  const SettingsCategoryRow({
    super.key,
    required this.icon,
    required this.title,
    this.summary,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: summary == null
          ? null
          : Text(summary, style: const TextStyle(fontSize: 12.5)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}

/// One opener at a time on a settings screen. A tap that lands while an
/// earlier one is still opening a screen or dialog (an `await` before the
/// push, a file picker), or while what it opened is still on top, is dropped
/// rather than stacking a second copy.
mixin SettingsOpenGuard<T extends StatefulWidget> on State<T> {
  bool _opening = false;

  Future<void> guardedOpen(Future<void> Function() open) async {
    if (_opening || ModalRoute.isCurrentOf(context) == false) return;
    _opening = true;
    try {
      await open();
    } finally {
      _opening = false;
    }
  }
}

/// The names of what is on, at most two, then "{count} more"; [none] when
/// nothing is. Same rule as the Site rows in site settings (BEHAV-002).
String summariseSettings(
  AppLocalizations loc,
  List<String> on, {
  required String none,
}) {
  if (on.isEmpty) return none;
  const separator = ' · ';
  final shown = on.take(2).join(separator);
  final overflow = on.length - 2;
  return overflow > 0
      ? '$shown$separator${loc.permissionsSummaryMore(overflow)}'
      : shown;
}

/// A count as the dataset rows write it: 1.2K, 98K, 640.
String formatSettingsCount(int n) {
  if (n >= 1000) {
    return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}K';
  }
  return n.toString();
}
