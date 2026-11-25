import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/web_view_model.dart';

/// The sidebar's icon: Flutter's `view_sidebar` draws its panel on the
/// right, so it is mirrored to show it on the left, where the sidebar is.
class SidebarIcon extends StatelessWidget {
  const SidebarIcon({super.key, this.size});

  final double? size;

  @override
  Widget build(BuildContext context) => Transform.flip(
    flipX: true,
    child: Icon(Icons.view_sidebar_outlined, size: size),
  );
}

/// The sidebar collapsed: one icon per site with its tab count, the site on
/// screen with a stripe per tab, its expand button on top and its cross at
/// the bottom. A tap anywhere no control takes expands it.
class SidebarRail extends StatelessWidget {
  const SidebarRail({
    super.key,
    required this.sites,
    required this.current,
    required this.width,
    required this.onOpen,
    required this.onOpenTab,
    required this.onExpand,
    required this.onHide,
  });

  final List<WebViewModel> sites;
  final WebViewModel? current;
  final double width;
  final ValueChanged<WebViewModel> onOpen;
  final void Function(WebViewModel site, {required TabId tabId}) onOpenTab;
  final VoidCallback onExpand;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onExpand,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: Chrome.bar(isDark: isDark),
          border: BorderDirectional(
            end: BorderSide(
              color: Chrome.hairline(isDark: isDark),
              width: Chrome.hairlineWidth,
            ),
          ),
        ),
        child: Column(
          children: [
            IconButton(
              tooltip: loc.sidebarExpand,
              color: scheme.primary,
              icon: const SidebarIcon(),
              onPressed: onExpand,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                children: [
                  for (final site in sites) ...[
                    _RailSite(
                      site: site,
                      on: identical(site, current),
                      onOpen: () => onOpen(site),
                    ),
                    if (identical(site, current) &&
                        site.effectiveTabsEnabled &&
                        site.tabs.length > 1)
                      _Stripes(site: site, onOpenTab: onOpenTab),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: loc.sidebarHide,
              icon: const Icon(Icons.close),
              onPressed: onHide,
            ),
          ],
        ),
      ),
    );
  }
}

class _RailSite extends StatelessWidget {
  const _RailSite({required this.site, required this.on, required this.onOpen});

  final WebViewModel site;
  final bool on;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = site.effectiveTabsEnabled ? site.tabs.length : 1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Center(
        child: Tooltip(
          message: site.getDisplayName(),
          // The count outside the square's Material, which paints its border
          // over its children.
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: on ? scheme.secondaryContainer : scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.lg),
                  side: BorderSide(
                    color: on ? scheme.primary : scheme.outlineVariant,
                    width: on ? 1.5 : Chrome.hairlineWidth,
                  ),
                ),
                child: InkWell(
                  onTap: onOpen,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: UnifiedFaviconImage.site(site, size: 22),
                    ),
                  ),
                ),
              ),
              if (count > 1)
                PositionedDirectional(
                  top: -5,
                  end: -5,
                  child: IgnorePointer(
                    child: TabCountPill(count: count, active: on),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A stripe per tab of the site on screen, the active one dark; a tap opens
/// that tab.
class _Stripes extends StatelessWidget {
  const _Stripes({required this.site, required this.onOpenTab});

  final WebViewModel site;
  final void Function(WebViewModel site, {required TabId tabId}) onOpenTab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final row in TabLifecycleEngine.treeOrder(site.tabs))
          Tooltip(
            message: row.tab.title?.isNotEmpty == true
                ? row.tab.title!
                : row.tab.url,
            child: InkWell(
              onTap: () => onOpenTab(site, tabId: row.tab.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Container(
                  width: 24,
                  height: 6,
                  decoration: BoxDecoration(
                    color: row.tab.id == site.activeTabId
                        ? scheme.primary
                        : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
