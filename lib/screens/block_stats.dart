import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';

/// App-wide protection report (STATS-003): what the blockers stopped over the
/// last 7 / 30 days, split by the mechanism that stopped it, plus the
/// all-time total since counting started.
class BlockStatsScreen extends StatefulWidget {
  const BlockStatsScreen({super.key});

  @override
  State<BlockStatsScreen> createState() => _BlockStatsScreenState();
}

class _BlockStatsScreenState extends State<BlockStatsScreen> {
  static const List<int> _ranges = [7, 30];

  int _rangeDays = 7;

  BlockStatsService get _service => BlockStatsService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onStatsChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onStatsChanged);
    super.dispose();
  }

  void _onStatsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _confirmReset() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.blockStatsReset),
        content: Text(loc.blockStatsResetConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.blockStatsReset),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.reset();
    if (!mounted) return;
    setState(() {});
  }

  String _categoryLabel(AppLocalizations loc, BlockCategory category) {
    switch (category) {
      case BlockCategory.filterList:
        return loc.blockStatsCategoryFilterList;
      case BlockCategory.dnsBlocklist:
        return loc.blockStatsCategoryDns;
      case BlockCategory.trackingParam:
        return loc.blockStatsCategoryParam;
      case BlockCategory.localCdn:
        return loc.blockStatsCategoryCdn;
    }
  }

  IconData _categoryIcon(BlockCategory category) {
    switch (category) {
      case BlockCategory.filterList:
        return Icons.block;
      case BlockCategory.dnsBlocklist:
        return Icons.dns_outlined;
      case BlockCategory.trackingParam:
        return Icons.link_off;
      case BlockCategory.localCdn:
        return Icons.cloud_off_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final engine = _service.engine;
    final totals = engine.totalsForLastDays(_rangeDays);
    final rangeTotal = totals.values.fold<int>(0, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.blockStatsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: loc.blockStatsReset,
            onPressed: engine.allTimeTotal == 0 ? null : _confirmReset,
          ),
        ],
      ),
      body: engine.allTimeTotal == 0
          ? _buildEmptyState(loc, theme)
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _buildHero(loc, theme, rangeTotal),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Center(
                    child: SegmentedButton<int>(
                      segments: [
                        for (final days in _ranges)
                          ButtonSegment<int>(
                            value: days,
                            label: Text(days == 7
                                ? loc.blockStatsRange7
                                : loc.blockStatsRange30),
                          ),
                      ],
                      selected: {_rangeDays},
                      showSelectedIcon: false,
                      onSelectionChanged: (selection) =>
                          setState(() => _rangeDays = selection.first),
                    ),
                  ),
                ),
                _buildChart(theme, engine.dailyTotals(_rangeDays)),
                const SizedBox(height: 20),
                ..._buildCategoryRows(loc, theme, totals, rangeTotal),
                const Divider(height: 32),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    loc.blockStatsSince(
                      engine.allTimeTotal,
                      MaterialLocalizations.of(context)
                          .formatShortDate(engine.since),
                    ),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildEmptyState(AppLocalizations loc, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined,
                size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(loc.blockStatsEmpty, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              loc.blockStatsEmptyHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(AppLocalizations loc, ThemeData theme, int total) {
    // Pure-data display goes through a variable, never a literal inside
    // Text(...) — LOC-002.
    final totalLabel = '$total';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.tertiaryContainer,
          ],
        ),
      ),
      child: Column(
        children: [
          Icon(Icons.shield,
              size: 56, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(height: 12),
          Text(
            totalLabel,
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _rangeDays == 7
                ? loc.blockStatsSubtitleWeek
                : loc.blockStatsSubtitleMonth,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
          ),
        ],
      ),
    );
  }

  /// Daily totals as a bare bar strip. Deliberately label-free: the axis
  /// values would need a locale-formatted date per bar and the shape is the
  /// point, not the readings.
  Widget _buildChart(ThemeData theme, List<int> daily) {
    final peak = daily.fold<int>(0, (a, b) => b > a ? b : a);
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final value in daily)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: FractionallySizedBox(
                    // A zero day draws nothing; any non-zero day gets a
                    // visible stub so a quiet day is not mistaken for none.
                    heightFactor: value == 0 ? 0.0 : (value / peak).clamp(0.04, 1.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCategoryRows(
    AppLocalizations loc,
    ThemeData theme,
    Map<BlockCategory, int> totals,
    int rangeTotal,
  ) {
    final ordered = BlockCategory.values.toList()
      ..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
    final rowLabels = <BlockCategory, String>{
      for (final category in ordered)
        category: '${totals[category] ?? 0}  ${_categoryLabel(loc, category)}',
    };
    return [
      for (final category in ordered)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(_categoryIcon(category),
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rowLabels[category]!,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: rangeTotal == 0
                            ? 0
                            : (totals[category] ?? 0) / rangeTotal,
                        minHeight: 6,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
  }
}
