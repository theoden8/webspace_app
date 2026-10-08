import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/theme/design_tokens.dart';

/// A number over its label, tinted by what it counts.
class StatChip extends StatelessWidget {
  const StatChip(this.value, this.label, this.color, {super.key});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      vertical: Spacing.sm - 2,
      horizontal: Spacing.xs,
    ),
    decoration: BoxDecoration(
      color: color.withAlpha(20),
      borderRadius: BorderRadius.circular(Radii.md),
      border: Border.all(color: color.withAlpha(50)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: TextStyle(fontSize: 9, color: color.withAlpha(180))),
      ],
    ),
  );
}

/// The four DNS counters, as the site's privacy screen and the developer
/// tools both show them.
class DnsStatChips extends StatelessWidget {
  const DnsStatChips(this.stats, {super.key, required this.padding});

  final DnsStats stats;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final rate = '${stats.blockRate.toStringAsFixed(1)}%';
    final chips = [
      StatChip('${stats.total}', loc.devToolsDnsTotal, Colors.blue),
      StatChip('${stats.allowed}', loc.devToolsDnsAllowed, Colors.green),
      StatChip('${stats.blocked}', loc.devToolsDnsBlocked, Colors.red),
      StatChip(
        rate,
        loc.devToolsDnsBlockRate,
        stats.blockRate > 0 ? Colors.orange : Colors.grey,
      ),
    ];
    return Padding(
      padding: padding,
      child: Row(
        spacing: Spacing.sm - 2,
        children: [for (final chip in chips) Expanded(child: chip)],
      ),
    );
  }
}
