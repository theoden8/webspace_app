import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';

/// A compact banner displayed at the top of the webview showing live DNS
/// blocking activity and (on Android) LocalCDN replacements per site.
/// Taps expand/collapse the banner. Automatically hides when there's no
/// activity to report.
class DnsBlockBanner extends StatefulWidget {
  final String siteId;
  final bool dnsBlockEnabled;
  final bool localCdnEnabled;

  const DnsBlockBanner({
    super.key,
    required this.siteId,
    required this.dnsBlockEnabled,
    this.localCdnEnabled = true,
  });

  @override
  State<DnsBlockBanner> createState() => _DnsBlockBannerState();
}

class _DnsBlockBannerState extends State<DnsBlockBanner> {
  bool _expanded = false;
  Timer? _refreshTimer;
  int _lastTotal = 0;
  int _lastCdnReplacements = 0;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final stats = DnsBlockService.instance.statsForSite(widget.siteId);
      final cdn = LocalCdnService.instance.replacementsForSite(widget.siteId);
      if (stats.total != _lastTotal || cdn != _lastCdnReplacements) {
        _lastTotal = stats.total;
        _lastCdnReplacements = cdn;
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
    final hasBlocklist = DnsBlockService.instance.hasBlocklist;
    final stats = DnsBlockService.instance.statsForSite(widget.siteId);
    final cdnReplacements =
        LocalCdnService.instance.replacementsForSite(widget.siteId);
    // Show the LocalCDN section on Android whenever LocalCDN is enabled for
    // this site and the cache has resources available — that way the user
    // sees "0 cdns replaced" as confirmation the feature is watching, and
    // the counter ticks up from there.
    final localCdnActive = Platform.isAndroid &&
        widget.localCdnEnabled &&
        LocalCdnService.instance.hasCache;
    final showCdnCount = localCdnActive || cdnReplacements > 0;

    // Nothing to show if there's no DNS activity and LocalCDN isn't active.
    if ((!hasBlocklist || stats.total == 0) && !showCdnCount) {
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
    final showDnsCounts = hasBlocklist && stats.total > 0;

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
                  if (showDnsCounts) ...[
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
                  ],
                  if (showCdnCount) ...[
                    if (showDnsCounts) const SizedBox(width: 12),
                    Icon(Icons.cloud_off, size: 14, color: textColor),
                    const SizedBox(width: 6),
                    Text(
                      '$cdnReplacements cdn${cdnReplacements == 1 ? '' : 's'} replaced',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (recentBlocked.isNotEmpty)
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
