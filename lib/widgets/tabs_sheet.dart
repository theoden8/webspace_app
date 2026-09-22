/// The tab list of a site, as a bottom sheet.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-008). Reached from the app bar's tab-count button and from a tap on
/// the active site's chip in the strip. Rows render in tree order — a tab sits
/// under the tab it was opened from — with the active tab marked, because it
/// is the only one of them holding a webview.
///
/// The widget owns no state beyond which subtrees are collapsed: the tab list
/// lives on the `WebViewModel`s and every mutation goes back to the host
/// through the callbacks, which is what keeps the capture/dispose/rebuild walk
/// in one place.
library;

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/services/tab_lifecycle_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';

/// One site as the sheet needs to see it. Keeps the sheet off `_currentIndex`
/// arithmetic: the host resolves indices, the sheet names sites by index.
class TabsSheetSite {
  const TabsSheetSite({
    required this.index,
    required this.model,
    required this.isCurrent,
  });

  final int index;
  final WebViewModel model;

  /// Whether this site is the one on screen. Only its active tab holds a
  /// webview; every other tab of every site is parked.
  final bool isCurrent;
}

class TabsSheet extends StatefulWidget {
  const TabsSheet({
    super.key,
    required this.sites,
    required this.currentIndex,
    required this.onOpenTab,
    required this.onNewTab,
    required this.onCloseTab,
    required this.onCloseSubtree,
    required this.onCloseParked,
  });

  /// Every site the current webspace shows, in display order.
  final List<TabsSheetSite> sites;

  /// Index into [sites] of the site whose tabs open first.
  final int currentIndex;

  final void Function(int siteIndex, String tabId) onOpenTab;
  final void Function(int siteIndex) onNewTab;
  final void Function(int siteIndex, String tabId) onCloseTab;
  final void Function(int siteIndex, String tabId) onCloseSubtree;
  final void Function(int siteIndex) onCloseParked;

  @override
  State<TabsSheet> createState() => _TabsSheetState();
}

class _TabsSheetState extends State<TabsSheet> {
  bool _allSites = false;
  final Set<String> _collapsed = <String>{};

  TabsSheetSite? get _site => widget.currentIndex >= 0 &&
          widget.currentIndex < widget.sites.length
      ? widget.sites[widget.currentIndex]
      : null;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final site = _site;
    if (site == null) return const SizedBox.shrink();
    final parked = site.model.tabs.length - 1;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _grabHandle(theme),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.lg, Spacing.xs, Spacing.sm, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      loc.tabsSheetTitle(
                          site.model.getDisplayName(), site.model.tabs.length),
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onNewTab(site.index);
                    },
                    icon: const Icon(Icons.add, size: IconSizes.action),
                    label: Text(loc.tabsNewTab),
                  ),
                ],
              ),
            ),
            if (widget.sites.length > 1) _scopeSwitch(loc, theme),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                children: _allSites
                    ? _allSitesRows(loc, theme)
                    : _rowsFor(site, loc, theme),
              ),
            ),
            const Divider(height: Chrome.hairlineWidth),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.lg, Spacing.xs, Spacing.sm, Spacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      loc.tabsOneWebview,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (parked > 0)
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onCloseParked(site.index);
                      },
                      child: Text(loc.tabsCloseParked(parked)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grabHandle(ThemeData theme) => Center(
        child: Container(
          width: 36,
          height: Spacing.xs,
          margin: const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.xs),
          decoration: BoxDecoration(
            color: theme.dividerColor,
            borderRadius: BorderRadius.circular(Radii.xs),
          ),
        ),
      );

  Widget _scopeSwitch(AppLocalizations loc, ThemeData theme) => Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.lg, Spacing.xs, Spacing.lg, Spacing.xs),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, label: Text(loc.tabsThisSite)),
            ButtonSegment(value: true, label: Text(loc.tabsAllSites)),
          ],
          selected: {_allSites},
          onSelectionChanged: (s) => setState(() => _allSites = s.first),
        ),
      );

  List<Widget> _allSitesRows(AppLocalizations loc, ThemeData theme) {
    final out = <Widget>[];
    for (final s in widget.sites) {
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.sm, Spacing.md, Spacing.sm, Spacing.xs),
        child: Text(
          loc.tabsSheetTitle(s.model.getDisplayName(), s.model.tabs.length),
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ));
      out.addAll(_rowsFor(s, loc, theme));
    }
    return out;
  }

  List<Widget> _rowsFor(
      TabsSheetSite site, AppLocalizations loc, ThemeData theme) {
    final rows = TabLifecycleEngine.treeOrder(site.model.tabs);
    final hidden = <String>{};
    final out = <Widget>[];
    for (final row in rows) {
      final parentId = row.tab.parentId;
      // A collapsed tab hides its whole subtree, so a descendant is hidden
      // when any ancestor is.
      if (parentId != null &&
          (hidden.contains(parentId) || _collapsed.contains(parentId))) {
        hidden.add(row.tab.id);
        continue;
      }
      out.add(_row(site, row, loc, theme));
    }
    return out;
  }

  Widget _row(TabsSheetSite site, TabRow row, AppLocalizations loc,
      ThemeData theme) {
    final tab = row.tab;
    final isActive = tab.id == site.model.activeTabId;
    // "Live" means this tab holds the webview: it is the active tab of the
    // site on screen. Every other row is a record plus a state file.
    final isLive = isActive && site.isCurrent;
    final collapsed = _collapsed.contains(tab.id);
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        widget.onOpenTab(site.index, tab.id);
      },
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          children: [
            SizedBox(width: row.depth * Spacing.lg),
            SizedBox(
              width: TapTargets.compact,
              height: TapTargets.compact,
              child: row.childCount == 0
                  ? const SizedBox.shrink()
                  : IconButton(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      iconSize: IconSizes.inline,
                      tooltip:
                          collapsed ? loc.tabsExpand : loc.tabsCollapse,
                      icon: Icon(collapsed
                          ? Icons.chevron_right
                          : Icons.keyboard_arrow_down),
                      onPressed: () => setState(() {
                        if (!_collapsed.remove(tab.id)) _collapsed.add(tab.id);
                      }),
                    ),
            ),
            UnifiedFaviconImage(
              url: site.model.initUrl,
              size: IconSizes.inline,
              proxy: site.model.outboundProxySettings,
              customIcon: site.model.customIconPng,
              persist: !site.model.isArchiveTier,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tab.title?.isNotEmpty == true ? tab.title! : tab.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isActive
                        ? theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)
                        : theme.textTheme.bodyMedium,
                  ),
                  Text(
                    // The whole subtree goes when a tab is collapsed, not just
                    // its direct children, so that is what the count says.
                    collapsed && row.childCount > 0
                        ? loc.tabsHiddenChildren(
                            TabLifecycleEngine.descendants(
                                    site.model.tabs, tab.id)
                                .length)
                        : extractDomain(tab.url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (isLive)
              Padding(
                padding: const EdgeInsets.only(right: Spacing.xs),
                child: Text(
                  loc.tabsLive,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            if (row.childCount > 0)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: IconSizes.action,
                tooltip: loc.tabsCloseSubtree,
                icon: const Icon(Icons.layers_clear_outlined),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onCloseSubtree(site.index, tab.id);
                },
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: IconSizes.action,
              tooltip: loc.tabsCloseTab,
              icon: const Icon(Icons.close),
              onPressed: () {
                Navigator.of(context).pop();
                widget.onCloseTab(site.index, tab.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}
