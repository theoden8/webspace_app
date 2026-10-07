import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/block_stats_service.dart';

/// Shield + the week's block count, the way into the protection report.
/// Reads the counters at build time rather than subscribing: it is shown on
/// the webspaces list, where no page is loading, and returning from a site
/// rebuilds it anyway.
class ProtectionShieldButton extends StatelessWidget {
  const ProtectionShieldButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final weekTotal = BlockStatsService.instance.engine.totalForLastDays(7);
    final scheme = Theme.of(context).colorScheme;
    return Badge.count(
      count: weekTotal,
      isLabelVisible: weekTotal > 0,
      // The accent, not the error red the badge defaults to: this counts
      // protection that worked, and an alarm colour reads as something the
      // user has to deal with.
      backgroundColor: scheme.primary,
      textColor: scheme.onPrimary,
      child: IconButton(
        icon: const Icon(Icons.shield_outlined),
        tooltip: AppLocalizations.of(context).blockStatsTitle,
        onPressed: onPressed,
      ),
    );
  }
}
