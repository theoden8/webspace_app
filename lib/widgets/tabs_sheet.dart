/// The tab list of a site, as a bottom sheet.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-008). Reached from the app bar's tab-count button and from a tap on
/// the active site's chip in the strip. Rows render in tree order — a tab sits
/// under the tab it was opened from — and say which tabs hold a webview: the
/// active tab of a loaded site does and draws at full strength, every other
/// tab is stored and drawn faded (TAB-011). A long press drags a tab and its
/// subtree to another place in the same site's tree (TAB-015).
///
/// The widget owns no state beyond which subtrees are collapsed and where a
/// drag would land: the tab list
/// lives on the `WebViewModel`s and every mutation goes back to the host
/// through the callbacks, which is what keeps the capture/dispose/rebuild walk
/// in one place.
library;

import 'dart:async';

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
    required this.isLoaded,
  });

  final int index;
  final WebViewModel model;

  /// Whether this site is the one on screen.
  final bool isCurrent;

  /// Whether the site holds a webview right now. The site load policy decides
  /// that (lazy loading, the LRU cap, memory pressure), not the tab list; when
  /// it does, the webview is its active tab's and every other tab is stored.
  final bool isLoaded;
}

class TabsSheet extends StatefulWidget {
  const TabsSheet({
    super.key,
    required this.sites,
    required this.currentIndex,
    required this.onOpenTab,
    required this.onNewTab,
    this.onWebSearch,
    required this.onCloseTab,
    required this.onCloseSubtree,
    this.onMoveTab,
    this.onMoveSite,
  });

  /// Every site the current webspace shows, in display order.
  final List<TabsSheetSite> sites;

  /// Index into [sites] of the site whose tabs open first.
  final int currentIndex;

  final void Function(int siteIndex, String tabId) onOpenTab;
  final void Function(int siteIndex) onNewTab;

  /// Opens web search for the site on screen (LIR-029); null hides it.
  final VoidCallback? onWebSearch;
  final void Function(int siteIndex, String tabId) onCloseTab;
  final void Function(int siteIndex, String tabId) onCloseSubtree;

  /// A tab dragged onto a row or past the last row (TAB-015). Returns whether
  /// the move was made. Null leaves the rows where they are.
  final bool Function(int siteIndex, String tabId, TabDrop drop)? onMoveTab;

  /// A site's heading dropped on another's in the All sites view (TAB-016):
  /// the site takes the other's place. Returns every site in its new order,
  /// or null when the move was refused. Null leaves the headings in place.
  final List<TabsSheetSite>? Function(String siteId, String ontoSiteId)?
      onMoveSite;

  @override
  State<TabsSheet> createState() => _TabsSheetState();
}

/// What a drag carries: the tab, its site, and the ids it may not land in.
class _DraggedTab {
  const _DraggedTab(this.siteIndex, this.tabId, this.subtree);

  final int siteIndex;
  final String tabId;
  final Set<String> subtree;
}

/// What a site heading's drag carries.
class _DraggedSite {
  const _DraggedSite(this.siteId);

  final String siteId;
}

class _TabsSheetState extends State<TabsSheet> {
  bool _allSites = false;

  /// [TabsSheet.sites] until a site moves; a move can renumber every site,
  /// so the host hands back the whole list.
  late List<TabsSheetSite> _sites = widget.sites;

  late final String? _currentId = widget.currentIndex >= 0 &&
          widget.currentIndex < widget.sites.length
      ? widget.sites[widget.currentIndex].model.siteId
      : null;
  final Set<String> _collapsed = <String>{};
  final ScrollController _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};

  /// Where the drag in progress would land: a row's key and zone, or a
  /// site's end-of-list key with no zone.
  String? _dropKey;
  TabDropZone? _dropZone;
  Timer? _autoScroll;

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  TabsSheetSite? get _site =>
      _sites.where((s) => s.model.siteId == _currentId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final site = _site;
    if (site == null) return const SizedBox.shrink();
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
              child: _header(site, loc, theme),
            ),
            if (_sites.length > 1) _scopeSwitch(loc, theme),
            Flexible(
              child: ListView(
                key: _listKey,
                controller: _scroll,
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
                  Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
              child: Text(
                loc.tabsMemoryNote,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The title, then Web search and New tab. A label that leaves the title
  /// too little room drops to its icon, Web search first, so the row fits a
  /// phone in every locale.
  Widget _header(TabsSheetSite site, AppLocalizations loc, ThemeData theme) {
    return LayoutBuilder(builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      double labelled(String label) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: theme.textTheme.labelLarge),
          textScaler: scaler,
          textDirection: direction,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        // TextButton.icon: 12 start, the icon, 8, the label, 16 end.
        return 36 + IconSizes.action + width;
      }

      const iconOnly = kMinInteractiveDimension;
      const titleRoom = 96.0;
      final search = widget.onWebSearch != null;
      var searchLabel = search;
      var newTabLabel = true;
      double needed() =>
          titleRoom +
          (!search ? 0 : searchLabel ? labelled(loc.webSearchMenu) : iconOnly) +
          (newTabLabel ? labelled(loc.tabsNewTab) : iconOnly);
      if (needed() > constraints.maxWidth) searchLabel = false;
      if (needed() > constraints.maxWidth) newTabLabel = false;

      Widget action(IconData icon, String label, bool withLabel,
          VoidCallback onPressed) {
        void run() {
          Navigator.of(context).pop();
          onPressed();
        }

        return withLabel
            ? TextButton.icon(
                onPressed: run,
                icon: Icon(icon, size: IconSizes.action),
                label: Text(label),
              )
            : IconButton(
                onPressed: run,
                tooltip: label,
                icon: Icon(icon, size: IconSizes.action),
                color: theme.colorScheme.primary,
              );
      }

      return Row(
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
          if (search)
            action(Icons.travel_explore, loc.webSearchMenu, searchLabel,
                widget.onWebSearch!),
          action(Icons.add, loc.tabsNewTab, newTabLabel,
              () => widget.onNewTab(site.index)),
        ],
      );
    });
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
    for (final s in _sites) {
      final label =
          loc.tabsSheetTitle(s.model.getDisplayName(), s.model.tabs.length);
      final heading = Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.sm, Spacing.md, Spacing.sm, Spacing.xs),
        child: Text(
          label,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      out.add(widget.onMoveSite == null
          ? heading
          : _siteDragAndDrop(s, heading, label, theme));
      out.addAll(_rowsFor(s, loc, theme));
    }
    return out;
  }

  /// A long press lifts a site's heading; a drop on another heading puts the
  /// site in that one's place, as the drawer and the tab strip do (TAB-016).
  Widget _siteDragAndDrop(
      TabsSheetSite site, Widget heading, String label, ThemeData theme) {
    final id = site.model.siteId;
    final key = 'site:$id';
    int position(String siteId) =>
        _sites.indexWhere((s) => s.model.siteId == siteId);

    return DragTarget<_DraggedSite>(
      onWillAcceptWithDetails: (d) => d.data.siteId != id,
      onMove: (_) {
        if (_dropKey != key) {
          setState(() {
            _dropKey = key;
            _dropZone = null;
          });
        }
      },
      onLeave: (_) {
        if (_dropKey == key) setState(() => _dropKey = _dropZone = null);
      },
      onAcceptWithDetails: (d) => _dropSite(d.data.siteId, id),
      builder: (context, candidates, _) {
        final from = candidates.isEmpty ? null : candidates.first?.siteId;
        // The site lands in this one's place: above it coming from below,
        // below it coming from above.
        final above = from != null && position(from) > position(id);
        return LongPressDraggable<_DraggedSite>(
          data: _DraggedSite(id),
          hitTestBehavior: HitTestBehavior.opaque,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragUpdate: (d) => _autoScrollAt(d.globalPosition),
          onDragEnd: (_) => _stopAutoScroll(),
          onDraggableCanceled: (_, _) => _stopAutoScroll(),
          feedback: _feedback(label, theme),
          childWhenDragging:
              Opacity(opacity: TabRows.draggingOpacity, child: heading),
          child: Stack(
            children: [
              heading,
              if (from != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: above ? 0 : null,
                  bottom: above ? null : 0,
                  height: TabRows.dropLineWidth,
                  child: IgnorePointer(
                      child: ColoredBox(color: theme.colorScheme.primary)),
                ),
            ],
          ),
        );
      },
    );
  }

  void _dropSite(String siteId, String ontoSiteId) {
    _stopAutoScroll();
    final moved = widget.onMoveSite?.call(siteId, ontoSiteId);
    setState(() {
      _dropKey = _dropZone = null;
      if (moved != null) _sites = moved;
    });
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
    if (widget.onMoveTab != null) out.add(_endTarget(site, theme));
    return out;
  }

  Widget _row(TabsSheetSite site, TabRow row, AppLocalizations loc,
      ThemeData theme) {
    final tab = row.tab;
    // A hosted tab runs as another site (LIR-018): the row shows that site's
    // icon and names it, since two rows with one URL can be two identities.
    final host = site.model.hostOf(tab);
    final identity = host ?? site.model;
    final domain = extractDomain(tab.url);
    final secondLine = host == null
        ? domain
        : '${loc.tabsRunsAs(host.getDisplayName())} · $domain';
    final isActive = tab.id == site.model.activeTabId;
    final isLoaded = isActive && site.isLoaded;
    final isOnScreen = isLoaded && site.isCurrent;
    final collapsed = _collapsed.contains(tab.id);
    final shape = BorderRadius.circular(Radii.lg);
    final rowBody = InkWell(
      onTap: () {
        Navigator.of(context).pop();
        widget.onOpenTab(site.index, tab.id);
      },
      borderRadius: shape,
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
            Expanded(
              // A stored tab is faded, as a browser fades an unloaded tab:
              // opening it reloads the page.
              child: Opacity(
                opacity: isLoaded ? 1 : TabRows.unloadedOpacity,
                child: Row(
                  children: [
                    UnifiedFaviconImage(
                      url: identity.initUrl,
                      size: IconSizes.inline,
                      proxy: identity.outboundProxySettings,
                      customIcon: identity.customIconPng,
                      persist: !identity.isArchiveTier,
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
                            style: theme.textTheme.bodyMedium,
                          ),
                          Text(
                            // The whole subtree goes when a tab is collapsed,
                            // not just its direct children, so that is what
                            // the count says.
                            collapsed && row.childCount > 0
                                ? loc.tabsHiddenChildren(
                                    TabLifecycleEngine.descendants(
                                            site.model.tabs, tab.id)
                                        .length)
                                : secondLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
    // The fade is the only visual cue, so a screen reader is told in words.
    final drawn = Semantics(
      selected: isOnScreen,
      value: isLoaded ? (isOnScreen ? loc.tabsLive : loc.tabsLoaded) : null,
      child: isOnScreen
          ? Ink(
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: shape,
              ),
              child: rowBody,
            )
          : rowBody,
    );
    if (widget.onMoveTab == null) return drawn;
    return _dragAndDrop(site, row, drawn, theme);
  }

  String _keyOf(TabsSheetSite site, String tabId) =>
      '${site.model.siteId}/$tabId';

  /// A long press lifts the row with its subtree; a drop in the top or
  /// bottom quarter of another row lands beside it, and in the middle, under
  /// it (TAB-015).
  Widget _dragAndDrop(
      TabsSheetSite site, TabRow row, Widget drawn, ThemeData theme) {
    final tab = row.tab;
    final key = _keyOf(site, tab.id);
    final rowKey = _rowKeys.putIfAbsent(key, GlobalKey.new);
    final expanded = row.childCount > 0 && !_collapsed.contains(tab.id);
    final dragged = _DraggedTab(site.index, tab.id, {
      tab.id,
      ...TabLifecycleEngine.descendants(site.model.tabs, tab.id)
          .map((t) => t.id),
    });

    TabDropZone zoneAt(Offset global) {
      final box = rowKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return TabDropZone.into;
      final y = box.globalToLocal(global).dy / box.size.height;
      if (y < 0.25) return TabDropZone.before;
      if (y > 0.75) return TabDropZone.after;
      return TabDropZone.into;
    }

    bool accepts(_DraggedTab d) =>
        d.siteIndex == site.index && !d.subtree.contains(tab.id);

    return DragTarget<_DraggedTab>(
      onWillAcceptWithDetails: (d) => accepts(d.data),
      onMove: (d) {
        if (!accepts(d.data)) return;
        final zone = zoneAt(d.offset);
        if (_dropKey != key || _dropZone != zone) {
          setState(() {
            _dropKey = key;
            _dropZone = zone;
          });
        }
      },
      onLeave: (_) {
        if (_dropKey == key) setState(() => _dropKey = _dropZone = null);
      },
      onAcceptWithDetails: (d) {
        final zone = zoneAt(d.offset);
        _drop(d.data, TabDrop.onto(tab.id, zone, targetExpanded: expanded),
            expand: zone == TabDropZone.into ? tab.id : null);
      },
      builder: (context, candidates, _) {
        final zone = candidates.isNotEmpty && _dropKey == key ? _dropZone : null;
        final indent = (row.depth +
                (zone == TabDropZone.after && expanded ? 1 : 0)) *
            Spacing.lg;
        final line = theme.colorScheme.primary;
        return LongPressDraggable<_DraggedTab>(
          data: dragged,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragUpdate: (d) => _autoScrollAt(d.globalPosition),
          onDragEnd: (_) => _stopAutoScroll(),
          onDraggableCanceled: (_, _) => _stopAutoScroll(),
          feedback: _feedback(
              tab.title?.isNotEmpty == true ? tab.title! : tab.url, theme),
          childWhenDragging:
              Opacity(opacity: TabRows.draggingOpacity, child: drawn),
          child: Stack(
            key: rowKey,
            children: [
              drawn,
              if (zone == TabDropZone.into)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: line.withValues(alpha: 0.08),
                        border: Border.all(
                            color: line, width: TabRows.dropLineWidth),
                        borderRadius: BorderRadius.circular(Radii.lg),
                      ),
                    ),
                  ),
                ),
              if (zone == TabDropZone.before || zone == TabDropZone.after)
                PositionedDirectional(
                  start: indent,
                  end: 0,
                  top: zone == TabDropZone.before ? 0 : null,
                  bottom: zone == TabDropZone.after ? 0 : null,
                  height: TabRows.dropLineWidth,
                  child: IgnorePointer(child: ColoredBox(color: line)),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Past a site's last row: the dragged tab becomes its last root.
  Widget _endTarget(TabsSheetSite site, ThemeData theme) {
    final key = 'end:${site.model.siteId}';
    return DragTarget<_DraggedTab>(
      onWillAcceptWithDetails: (d) => d.data.siteIndex == site.index,
      onMove: (_) {
        if (_dropKey != key) {
          setState(() {
            _dropKey = key;
            _dropZone = null;
          });
        }
      },
      onLeave: (_) {
        if (_dropKey == key) setState(() => _dropKey = _dropZone = null);
      },
      onAcceptWithDetails: (d) => _drop(d.data, const TabDrop.toEnd()),
      builder: (context, candidates, _) => SizedBox(
        height: Spacing.xl,
        child: candidates.isNotEmpty
            ? Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: TabRows.dropLineWidth,
                  width: double.infinity,
                  child: ColoredBox(color: theme.colorScheme.primary),
                ),
              )
            : null,
      ),
    );
  }

  void _drop(_DraggedTab d, TabDrop drop, {String? expand}) {
    _stopAutoScroll();
    final moved = widget.onMoveTab?.call(d.siteIndex, d.tabId, drop) ?? false;
    setState(() {
      _dropKey = _dropZone = null;
      if (moved && expand != null) _collapsed.remove(expand);
    });
  }

  Widget _feedback(String label, ThemeData theme) => Transform.translate(
        // Above and beside the finger, so the row it names stays readable.
        offset: const Offset(-Spacing.lg, -Spacing.xl * 2),
        child: Material(
          elevation: Elevations.floatingActive,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md, vertical: Spacing.sm),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ),
      );

  /// Scroll the list while a drag holds near its top or bottom edge, so a tab
  /// can reach a row that is off screen.
  void _autoScrollAt(Offset global) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !_scroll.hasClients) return;
    final y = box.globalToLocal(global).dy;
    final step = y < TabRows.autoScrollEdge
        ? -TabRows.autoScrollStep
        : y > box.size.height - TabRows.autoScrollEdge
            ? TabRows.autoScrollStep
            : 0.0;
    if (step == 0) {
      _stopAutoScroll();
      return;
    }
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(Motion.autoScrollTick, (_) {
      if (!_scroll.hasClients) return _stopAutoScroll();
      final p = _scroll.position;
      final to = (p.pixels + step).clamp(p.minScrollExtent, p.maxScrollExtent);
      if (to == p.pixels) return _stopAutoScroll();
      _scroll.jumpTo(to);
    });
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }
}
