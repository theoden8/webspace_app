import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/site_permission_state.dart';

/// Localized one-word label for [state].
String sitePermissionStateLabel(
  AppLocalizations loc,
  SitePermissionState state,
) =>
    switch (state) {
      SitePermissionState.ask => loc.permissionStateAsk,
      SitePermissionState.allowed => loc.permissionStateAllowed,
      SitePermissionState.simulated => loc.permissionStateSimulated,
      SitePermissionState.blocked => loc.permissionStateBlocked,
    };

/// The trailing state marker on a permission row.
///
/// Colour carries the same meaning as the drawer badge: error tint when a real
/// device is open, the accent container when the page is being served a file,
/// and nothing loud for the two states where the site holds nothing. Keeping
/// one encoding across both surfaces is the point — a glance at the drawer and
/// a glance at this screen cannot disagree.
class SitePermissionChip extends StatelessWidget {
  const SitePermissionChip({super.key, required this.state, this.dimmed = false});

  final SitePermissionState state;

  /// Rendered inert, for a capability another setting has taken over (tracking
  /// protection forcing DRM off, an archived webspace, a proxy conflict).
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context);
    final label = sitePermissionStateLabel(loc, state);

    Color? background;
    Color foreground;
    BoxBorder? border;
    switch (state) {
      case SitePermissionState.allowed:
        background = scheme.errorContainer;
        foreground = scheme.onErrorContainer;
        break;
      case SitePermissionState.simulated:
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
        break;
      case SitePermissionState.ask:
        foreground = scheme.onSurfaceVariant;
        border = Border.all(color: scheme.outlineVariant);
        break;
      case SitePermissionState.blocked:
        // Deliberately the quietest of the four: nothing is reaching the site,
        // so nothing should draw the eye.
        foreground = scheme.onSurfaceVariant;
        break;
    }

    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          border: border,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: foreground,
          ),
        ),
      ),
    );
  }
}
