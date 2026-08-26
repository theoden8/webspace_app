import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/block_stats_detail.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';

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

/// Daily totals as a bare bar strip. Deliberately label-free: the axis
/// values would need a locale-formatted date per bar and the shape is the
/// point, not the readings.
Widget _dailyBars(ThemeData theme, List<int> daily) {
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
                  heightFactor:
                      value == 0 || peak == 0 ? 0.0 : (value / peak).clamp(0.04, 1.0),
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

/// App-wide protection report (STATS-003): what the blockers stopped over the
/// last 7 / 30 days, split by the mechanism that stopped it, plus the
/// all-time total since counting started.
class BlockStatsScreen extends StatefulWidget {
  /// `siteId` -> display name for the sites the drill-down may name. Only
  /// app-tier sites belong here: an archive-tier site never contributes a
  /// count in the first place (STATS-005).
  final Map<String, String> siteNames;

  const BlockStatsScreen({super.key, this.siteNames = const {}});

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
                _dailyBars(theme, engine.dailyTotals(_rangeDays)),
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
        InkWell(
          key: Key('block_stats_category_${category.name}'),
          onTap: () => _openCategory(category),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
    ];
  }

  void _openCategory(BlockCategory category) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlockStatsCategoryScreen(
          category: category,
          rangeDays: _rangeDays,
          siteNames: widget.siteNames,
        ),
      ),
    );
  }
}

/// One category of the protection report, opened from its row (STATS-008).
///
/// Counts and chart come from the persisted daily buckets; the lists of what
/// was actually stopped and which site it was stopped for come from the
/// encrypted detail blob (STATS-009). Both survive a restart, so the two
/// halves of the screen no longer disagree after one.
class BlockStatsCategoryScreen extends StatefulWidget {
  final BlockCategory category;
  final int rangeDays;
  final Map<String, String> siteNames;

  const BlockStatsCategoryScreen({
    super.key,
    required this.category,
    required this.rangeDays,
    this.siteNames = const {},
  });

  @override
  State<BlockStatsCategoryScreen> createState() =>
      _BlockStatsCategoryScreenState();
}

class _BlockStatsCategoryScreenState extends State<BlockStatsCategoryScreen> {
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final engine = _service.engine;
    final detail = _service.detail;
    final category = widget.category;
    final rangeTotal = engine.totalsForLastDays(widget.rangeDays)[category] ?? 0;
    final items = detail.topItems(category);
    final sites = _namedSiteCounts(detail);

    return Scaffold(
      appBar: AppBar(title: Text(_categoryLabel(loc, category))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildHeader(loc, theme, rangeTotal),
          _dailyBars(
            theme,
            engine.dailyTotals(widget.rangeDays, category: category),
          ),
          const SizedBox(height: 20),
          if (items.isEmpty && sites.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                loc.blockStatsDetailEmpty,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (items.isNotEmpty) ...[
            _sectionHeader(theme, loc.blockStatsDetailItems),
            for (final item in items)
              _countRow(theme, item.label, item.count,
                  icon: _categoryIcon(category)),
          ],
          if (sites.isNotEmpty) ...[
            _sectionHeader(theme, loc.blockStatsDetailSites),
            for (final site in sites)
              _countRow(theme, site.key, site.value,
                  icon: Icons.public_outlined),
          ],
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              loc.blockStatsSince(
                engine.allTimeFor(category),
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

  /// Per-site counts, resolved to display names. A site deleted since its
  /// row was written has no name left to show, so it drops out rather than
  /// surfacing a raw `siteId`.
  List<MapEntry<String, int>> _namedSiteCounts(BlockStatsDetail detail) {
    final out = <MapEntry<String, int>>[];
    for (final entry in detail.siteCounts(widget.category)) {
      final name = widget.siteNames[entry.key];
      if (name == null || name.isEmpty) continue;
      out.add(MapEntry(name, entry.value));
    }
    return out;
  }

  Widget _buildHeader(AppLocalizations loc, ThemeData theme, int total) {
    final totalLabel = '$total';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            totalLabel,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            widget.rangeDays == 7
                ? loc.blockStatsSubtitleWeek
                : loc.blockStatsSubtitleMonth,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.titleSmall
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }

  Widget _countRow(ThemeData theme, String label, int count,
      {required IconData icon}) {
    final countLabel = '$count';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            countLabel,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
