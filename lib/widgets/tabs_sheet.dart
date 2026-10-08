/// The tab list of a site, as a bottom sheet.
///
/// Spec: `openspec/changes/inactive-tabs/specs/inactive-tabs/spec.md`
/// (TAB-008). Reached from the app bar's tab-count button and from a tap on
/// the active site's chip in the strip. Rows render in tree order — a tab sits
/// under the tab it was opened from — and say which tabs hold a webview: the
/// active tab of a loaded site does and draws at full strength, every other
/// tab is stored and drawn faded (TAB-011). A long press drags a tab and its
/// subtree to another place in the same site's tree (TAB-015). Each row is
/// marked with the colour of the container it runs in (TAB-018). The This
/// site list is the tree of the site on screen, whatever its tab runs as, and
/// below it every other site's tree that holds a tab running as a site on the
/// branch through that tab (TAB-017), so a tab in another tree and the way
/// back to the one before are both a tap away (TAB-019).
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
import 'package:webspace/services/tab_list_engine.dart';
import 'package:webspace/services/tab_return_engine.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/container_mark.dart';

/// One site as the sheet needs to see it. Keeps the sheet off `_currentIndex`
/// arithmetic: the host resolves indices, the sheet names sites by index.
class TabsSheetSite {
  const TabsSheetSite({
    required this.index,
    required this.model,
    required this.isCurrent,
    required this.isLoaded,
    this.inView = true,
  });

  final int index;
  final WebViewModel model;

  /// Whether this site is the one on screen.
  final bool isCurrent;

  /// Whether the site holds a webview right now. The site load policy decides
  /// that (lazy loading, the LRU cap, memory pressure), not the tab list; when
  /// it does, the webview is its active tab's and every other tab is stored.
  final bool isLoaded;

  /// Whether the current webspace shows this site. One it does not show gets
  /// no heading or rows of its own; it is listed so that the tabs in its tree
  /// that run as the site on screen are (TAB-017).
  final bool inView;
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
    this.wayBack,
  });

  /// Every site with tabs: those the current webspace shows, in display
  /// order, then the rest.
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

  /// The jump Back would undo from the tab on screen (TAB-019): the tab it
  /// came from is marked as where the user was, and its tree is listed.
  final TabReturn? wayBack;

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

  /// Other sites' trees shown whole rather than folded around the tabs that
  /// run as the site the list is for.
  final Set<String> _unfolded = <String>{};
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

  /// The site on screen, whose tree This site lists first, whatever the tab
  /// on screen runs as (LIR-018).
  TabsSheetSite? get _site =>
      _sites.where((s) => s.model.siteId == _currentId).firstOrNull;

  List<TabsSheetSite> get _shown => [
        for (final s in _sites)
          if (s.inView) s,
      ];

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
            if (_shown.length > 1) _scopeSwitch(loc, theme),
            Flexible(
              child: ListView(
                key: _listKey,
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                children: _allSites
                    ? _allSitesRows(loc, theme)
                    : [
                        ..._rowsFor(site, loc, theme),
                        ..._otherTrees(site, loc, theme),
                      ],
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
              VoidCallback onPressed) =>
          withLabel
              ? TextButton.icon(
                  onPressed: _closing(onPressed),
                  icon: Icon(icon, size: IconSizes.action),
                  label: Text(label),
                )
              : IconButton(
                  onPressed: _closing(onPressed),
                  tooltip: label,
                  icon: Icon(icon, size: IconSizes.action),
                  color: theme.colorScheme.primary,
                );

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
    for (final s in _shown) {
      final label =
          loc.tabsSheetTitle(s.model.getDisplayName(), s.model.tabs.length);
      final heading = _heading(label, theme, site: s);
      out.add(widget.onMoveSite == null
          ? heading
          : _siteDragAndDrop(s, heading, label, theme));
      out.addAll(_rowsFor(s, loc, theme));
    }
    return out;
  }

  /// A heading over a site's rows, marked with the site's own container when
  /// it heads that site's tree.
  Widget _heading(String label, ThemeData theme, {TabsSheetSite? site}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(
            Spacing.sm, Spacing.md, Spacing.sm, Spacing.xs),
        child: Row(
          children: [
            if (site != null) ...[
              ContainerMark(site: site.model),
              const SizedBox(width: Spacing.sm),
            ],
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );

  /// TAB-017: after the tree of [site], the site on screen, every other
  /// site's tree, in the current webspace or not, that holds a tab running as
  /// a site on the branch through the tab on screen, folded around those tabs
  /// and in branch order ([TabListEngine]); and the tree holding where the
  /// user was (TAB-019), so the way back is listed too. The rows stay in that
  /// site's tree: a tap opens that site on the tab, a close closes it there,
  /// and they are not dragged from here.
  List<Widget> _otherTrees(
      TabsSheetSite site, AppLocalizations loc, ThemeData theme) {
    final back = widget.wayBack;
    final listed = TabListEngine.otherTrees(
      containers:
          TabListEngine.branchContainers(_treeOf(site), site.model.activeTabId),
      selected: site.model.runningIdentity.siteId,
      others: [
        for (final other in _sites)
          if (other.model.siteId != site.model.siteId) _treeOf(other),
      ],
      keep: (siteId, t) => back?.leadsBackTo(siteId, t.id) ?? false,
    );
    final out = <Widget>[];
    for (final tree in listed) {
      final other = _sites.firstWhere((s) => s.model.siteId == tree.siteId);
      final rows = _unfolded.contains(tree.siteId)
          ? TabLifecycleEngine.treeOrder(other.model.tabs)
          : tree.rows;
      out.add(_heading(loc.tabsInSite(other.model.getDisplayName()), theme,
          site: other));
      out.addAll(_rowsOf(other, rows, loc, theme, draggable: false));
      final folded = other.model.tabs.length - rows.length;
      if (folded > 0) out.add(_foldRow(other, folded, loc, theme));
    }
    return out;
  }

  TabTree _treeOf(TabsSheetSite s) => TabTree(s.model.siteId, s.model.tabs,
      (t) => (s.model.hostOf(t) ?? s.model).siteId);

  /// The rest of another site's tree, folded away; a tap shows it whole.
  Widget _foldRow(TabsSheetSite other, int count, AppLocalizations loc,
          ThemeData theme) =>
      InkWell(
        onTap: () => setState(() => _unfolded.add(other.model.siteId)),
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
          child: Row(
            children: [
              const SizedBox(
                width: TapTargets.compact,
                child: Icon(Icons.keyboard_arrow_down, size: IconSizes.inline),
              ),
              Expanded(
                child: Text(
                  loc.tabsMoreInSite(count, other.model.getDisplayName()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
        ),
      );

  /// A long press lifts a site's heading; a drop on another heading puts the
  /// site in that one's place, as the drawer and the tab strip do (TAB-016).
  Widget _siteDragAndDrop(
      TabsSheetSite site, Widget heading, String label, ThemeData theme) {
    final id = site.model.siteId;
    final key = 'site:$id';
    int position(String siteId) =>
        _shown.indexWhere((s) => s.model.siteId == siteId);

    return DragTarget<_DraggedSite>(
      onWillAcceptWithDetails: (d) => d.data.siteId != id,
      onMove: (_) => _hover(key),
      onLeave: (_) => _unhover(key),
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

  /// Marks [key], and [zone] in it, as where the drag in progress would land.
  void _hover(String key, [TabDropZone? zone]) {
    if (_dropKey == key && _dropZone == zone) return;
    setState(() {
      _dropKey = key;
      _dropZone = zone;
    });
  }

  void _unhover(String key) {
    if (_dropKey == key) setState(() => _dropKey = _dropZone = null);
  }

  /// Closes the sheet, then hands [action] to the host.
  VoidCallback _closing(VoidCallback action) => () {
        Navigator.of(context).pop();
        action();
      };

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
    final out = _rowsOf(
        site, TabLifecycleEngine.treeOrder(site.model.tabs), loc, theme,
        draggable: widget.onMoveTab != null);
    if (widget.onMoveTab != null) out.add(_endTarget(site, theme));
    return out;
  }

  List<Widget> _rowsOf(TabsSheetSite site, List<TabRow> rows,
      AppLocalizations loc, ThemeData theme,
      {required bool draggable}) {
    final hidden = <String>{};
    final out = <Widget>[];
    for (final row in rows) {
      final parentId = row.tab.parentId;
      // A collapsed tab hides its whole subtree, so a descendant is hidden
      // when any ancestor is. A row at depth 0 is a root as shown, whatever
      // it hangs from in its own tree.
      if (row.depth > 0 &&
          parentId != null &&
          (hidden.contains(parentId) ||
              _collapsed.contains(_keyOf(site, parentId)))) {
        hidden.add(row.tab.id);
        continue;
      }
      out.add(_row(site, row, loc, theme, draggable: draggable));
    }
    return out;
  }

  Widget _row(TabsSheetSite site, TabRow row, AppLocalizations loc,
      ThemeData theme,
      {required bool draggable}) {
    final tab = row.tab;
    // A hosted tab runs as another site (LIR-018), a foreign one as its owner
    // in another site's domain (LIR-034): the row shows the site it runs as
    // and names it, since two rows with one URL can be two identities.
    final host = site.model.hostOf(tab);
    final identity = host ?? site.model;
    final domain = extractDomain(tab.url);
    final runsAs = host == null && !site.model.isForeignTab(tab)
        ? domain
        : '${loc.tabsRunsAs(identity.getDisplayName())} · $domain';
    final secondLine =
        widget.wayBack?.leadsBackTo(site.model.siteId, tab.id) ?? false
            ? '$runsAs · ${loc.tabsWhereYouWere}'
            : runsAs;
    final isActive = tab.id == site.model.activeTabId;
    final isLoaded = isActive && site.isLoaded;
    final isOnScreen = isLoaded && site.isCurrent;
    final collapseKey = _keyOf(site, tab.id);
    final collapsed = _collapsed.contains(collapseKey);
    final shape = BorderRadius.circular(Radii.lg);
    Widget close(String tooltip, IconData icon,
            void Function(int siteIndex, String tabId) onClose) =>
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: IconSizes.action,
          tooltip: tooltip,
          icon: Icon(icon),
          onPressed: _closing(() => onClose(site.index, tab.id)),
        );
    final rowBody = InkWell(
      onTap: _closing(() => widget.onOpenTab(site.index, tab.id)),
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
                        if (!_collapsed.remove(collapseKey)) {
                          _collapsed.add(collapseKey);
                        }
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
                    ContainerMark(site: identity),
                    const SizedBox(width: Spacing.xs),
                    UnifiedFaviconImage.site(identity, size: IconSizes.inline),
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
              close(loc.tabsCloseSubtree, Icons.layers_clear_outlined,
                  widget.onCloseSubtree),
            close(loc.tabsCloseTab, Icons.close, widget.onCloseTab),
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
    if (!draggable || widget.onMoveTab == null) return drawn;
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
    final expanded = row.childCount > 0 && !_collapsed.contains(key);
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
        if (accepts(d.data)) _hover(key, zoneAt(d.offset));
      },
      onLeave: (_) => _unhover(key),
      onAcceptWithDetails: (d) {
        final zone = zoneAt(d.offset);
        _drop(d.data, TabDrop.onto(tab.id, zone, targetExpanded: expanded),
            expand: zone == TabDropZone.into ? key : null);
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
      onMove: (_) => _hover(key),
      onLeave: (_) => _unhover(key),
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
