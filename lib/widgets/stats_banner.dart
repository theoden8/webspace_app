import 'dart:async';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/widgets/block_category_label.dart';

/// A compact banner displayed at the top of the webview showing live
/// block activity per site (DNS + ABP merged). A tap expands it to what each
/// blocker stopped and the hosts blocked most. Automatically hides when
/// there's no activity to report.
class StatsBanner extends StatefulWidget {
  final SiteId siteId;
  final bool dnsBlockEnabled;

  const StatsBanner({
    super.key,
    required this.siteId,
    required this.dnsBlockEnabled,
  });

  @override
  State<StatsBanner> createState() => _StatsBannerState();
}

class _StatsBannerState extends State<StatsBanner> {
  bool _expanded = false;
  Timer? _refreshTimer;
  int _lastTotal = 0;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final stats = DnsBlockService.instance.statsForSite(widget.siteId);
      if (stats.total != _lastTotal) {
        _lastTotal = stats.total;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dns = DnsBlockService.instance;
    if (!dns.hasBlocklist && !ContentBlockerService.instance.hasRules) {
      return const SizedBox.shrink();
    }
    final stats = dns.statsForSite(widget.siteId);
    if (stats.total == 0) return const SizedBox.shrink();

    final topBlocked = stats.topBlockedHosts(limit: 5);

    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark
        ? Colors.grey.shade900.withAlpha(200)
        : Colors.grey.shade100;
    final textColor = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
    final subtleColor = isDark ? Colors.grey.shade400 : Colors.grey.shade500;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(
              bottom: BorderSide(
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.shield, size: 14, color: textColor),
                  const SizedBox(width: 6),
                  Text(
                    loc.statsBannerBlocked(stats.blocked),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    loc.statsBannerAllowed(stats.allowed),
                    style: TextStyle(fontSize: 11, color: subtleColor),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: subtleColor,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 4),
                for (final source in BlockSource.values)
                  _CountRow(
                    icon: source.category.icon,
                    label: source.category.label(loc),
                    count: stats.blockedBy(source),
                    style: TextStyle(fontSize: 11, color: subtleColor),
                  ),
                if (topBlocked.isNotEmpty) ...[
                  Padding(
                    padding:
                        const EdgeInsetsDirectional.only(start: 20, top: 6),
                    child: Text(
                      loc.blockStatsDetailItems,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: subtleColor,
                      ),
                    ),
                  ),
                  for (final (:host, :count) in topBlocked)
                    _CountRow(
                      icon: Icons.block,
                      label: host,
                      count: count,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: subtleColor,
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One count in the expanded banner: what it counts, then how many.
class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.style,
  });

  final IconData icon;
  final String label;
  final int count;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 20, top: 1),
        child: Row(
          children: [
            Icon(icon, size: 11, color: style.color),
            const SizedBox(width: 4),
            Expanded(
              child: Text(label, style: style, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            Text(
              MaterialLocalizations.of(context).formatDecimal(count),
              style: style,
            ),
          ],
        ),
      );
}
