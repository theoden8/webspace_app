import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/services/dns_block_service.dart';

/// A compact banner displayed at the top of the webview showing live DNS
/// blocking activity. Shows recently blocked domains and per-site stats.
/// Taps expand/collapse the banner. Automatically hides when no blocks occur.
class DnsBlockBanner extends StatefulWidget {
  final String siteId;
  final bool dnsBlockEnabled;

  const DnsBlockBanner({
    super.key,
    required this.siteId,
    required this.dnsBlockEnabled,
  });

  @override
  State<DnsBlockBanner> createState() => _DnsBlockBannerState();
}

class _DnsBlockBannerState extends State<DnsBlockBanner> {
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
    if (!DnsBlockService.instance.hasBlocklist) {
      return const SizedBox.shrink();
    }

    final stats = DnsBlockService.instance.statsForSite(widget.siteId);
    if (stats.total == 0) {
      return const SizedBox.shrink();
    }

    // Get the most recent blocked domains (unique, up to 5)
    final recentBlocked = <String>[];
    for (int i = stats.log.length - 1; i >= 0 && recentBlocked.length < 5; i--) {
      final entry = stats.log[i];
      if (entry.blocked && !recentBlocked.contains(entry.domain)) {
        recentBlocked.add(entry.domain);
      }
    }

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
                    '${stats.blocked} blocked',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${stats.allowed} allowed',
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
                ...recentBlocked.map((domain) => Padding(
                      padding: const EdgeInsets.only(left: 20, top: 1),
                      child: Row(
                        children: [
                          Icon(Icons.block, size: 11, color: subtleColor),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              domain,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: subtleColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
