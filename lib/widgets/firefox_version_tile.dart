import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/widgets/hint_button.dart';

/// App-settings row for the Firefox version generated User-Agents render at.
/// Both refresh modes hang off the one entry: the button checks now, the
/// sub-row switch arms the weekly check at startup. What each costs in network
/// terms is in the hint dialog.
class FirefoxVersionTile extends StatelessWidget {
  final int majorVersion;
  final DateTime? lastChecked;
  final bool isUpdating;
  final bool autoUpdate;
  final VoidCallback onUpdate;
  final ValueChanged<bool> onAutoUpdateChanged;

  const FirefoxVersionTile({
    super.key,
    required this.majorVersion,
    required this.lastChecked,
    required this.isUpdating,
    required this.autoUpdate,
    required this.onUpdate,
    required this.onAutoUpdateChanged,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final description = '${loc.appSettingsFirefoxVersionHint}\n\n'
        '${loc.appSettingsFirefoxAutoUpdate}: '
        '${loc.appSettingsFirefoxAutoUpdateHint}';
    final checked = lastChecked?.toLocal().toString().split('.')[0];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.travel_explore),
          title: Row(
            children: [
              Flexible(child: Text(loc.appSettingsFirefoxVersion)),
              HintButton(
                title: loc.appSettingsFirefoxVersion,
                description: description,
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(loc.appSettingsFirefoxVersionCurrent(majorVersion)),
              if (checked != null)
                Text(
                  loc.appSettingsFirefoxVersionChecked(checked),
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
          trailing: isUpdating
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: loc.appSettingsUpdateFirefoxVersion,
                  onPressed: onUpdate,
                ),
        ),
        SwitchListTile(
          // start: the title column. end: 24 puts the switch track flush
          // with the refresh icon above it, which sits inset in its button.
          contentPadding: const EdgeInsetsDirectional.only(start: 72, end: 24),
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(
            loc.appSettingsFirefoxAutoUpdate,
            style: const TextStyle(fontSize: 13),
          ),
          value: autoUpdate,
          onChanged: onAutoUpdateChanged,
        ),
      ],
    );
  }
}
