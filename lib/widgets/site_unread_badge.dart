import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/site_unread_service.dart';

/// Composed from the per-site settings string rather than new copy, like the
/// permission badges beside it.
String siteUnreadBadgeLabel(AppLocalizations loc, int count) =>
    '${loc.siteSettingsNotifications}: $count';

/// Count pill for a site's unread state ([SiteUnreadService.count]), or
/// nothing while it has none. Listens on its own, so a count that moves
/// rebuilds the pill and not the tile or tab around it.
class SiteUnreadBadge extends StatelessWidget {
  const SiteUnreadBadge({
    super.key,
    required this.siteId,
    this.padding = EdgeInsets.zero,
    this.service,
  });

  final String siteId;

  /// Applied only while the pill shows, so a site with nothing unread takes
  /// no room at all.
  final EdgeInsetsGeometry padding;

  /// Defaults to [SiteUnreadService.instance].
  final SiteUnreadService? service;

  @override
  Widget build(BuildContext context) {
    final unread = service ?? SiteUnreadService.instance;
    return ListenableBuilder(
      listenable: unread,
      builder: (context, _) {
        final count = unread.count(siteId);
        if (count == 0) return const SizedBox.shrink();
        return Padding(
          padding: padding,
          child: Semantics(
            label: siteUnreadBadgeLabel(AppLocalizations.of(context), count),
            excludeSemantics: true,
            child: Badge.count(count: count, maxCount: 99),
          ),
        );
      },
    );
  }
}

/// The drawer's menu glyph, with a dot while any of [siteIds] has unread, so
/// a count on a site that is not on screen is noticed without opening the
/// drawer.
class UnreadMenuIcon extends StatelessWidget {
  const UnreadMenuIcon({super.key, required this.siteIds, this.service});

  final List<String> siteIds;

  /// Defaults to [SiteUnreadService.instance].
  final SiteUnreadService? service;

  @override
  Widget build(BuildContext context) {
    final unread = service ?? SiteUnreadService.instance;
    return ListenableBuilder(
      listenable: unread,
      builder: (context, _) {
        final any = unread.anyUnread(siteIds);
        final icon = Badge(isLabelVisible: any, child: const Icon(Icons.menu));
        if (!any) return icon;
        return Semantics(
          label: AppLocalizations.of(context).siteSettingsNotifications,
          child: icon,
        );
      },
    );
  }
}
