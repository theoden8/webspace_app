import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/launcher_grid.dart';
import 'package:webspace/widgets/launcher_slot.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_list_menu.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

enum _GroupAction { edit, delete }

/// The user's sites as a phone's home screen: webspaces are its folders, and
/// the selected one opens as a panel grown out of its tile over the dimmed
/// grid (WEBSPACE-008). Search and whether a folder is open are UI state.
class WebspaceLibrary extends StatefulWidget {
  const WebspaceLibrary({
    super.key,
    required this.webspaces,
    required this.sites,
    required this.selectedWebspaceId,
    required this.currentSite,
    required this.showsTabCount,
    required this.onSelectWebspace,
    required this.onAddWebspace,
    required this.onEditWebspace,
    required this.onDeleteWebspace,
    required this.onReorder,
    required this.onOpenSite,
    required this.onSiteMenu,
    required this.onReorderSite,
    required this.onAddSite,
    required this.onShowTabs,
    required this.onOpenSettings,
  });

  final List<Webspace> webspaces;
  final List<WebViewModel> sites;
  final WebspaceId? selectedWebspaceId;
  final WebViewModel? currentSite;
  final bool Function(WebViewModel site) showsTabCount;
  final ValueChanged<Webspace> onSelectWebspace;
  final VoidCallback onAddWebspace;
  final ValueChanged<Webspace> onEditWebspace;
  final ValueChanged<Webspace> onDeleteWebspace;
  final void Function(int from, {required int newIndex})? onReorder;
  final ValueChanged<WebViewModel> onOpenSite;
  final void Function(
    BuildContext context, {
    required WebViewModel site,
    required Offset position,
  })
  onSiteMenu;
  final void Function(int from, {required int to})? onReorderSite;
  final VoidCallback onAddSite;

  /// The tab tree of every site [scope] holds: all sites from the home
  /// header, the open folder's from its panel.
  final void Function(WebspaceId scope) onShowTabs;
  final Future<void> Function() onOpenSettings;

  @override
  State<WebspaceLibrary> createState() => WebspaceLibraryState();
}

/// Owns the open folder and the search without changing saved app state.
class WebspaceLibraryState extends State<WebspaceLibrary>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _settings = ReentryGuard();
  late final AnimationController _panel;
  late final CurvedAnimation _growth;

  /// Whether the selected webspace is open. Its panel is still shrinking for
  /// a moment after this goes false, and takes no input meanwhile.
  bool _open = false;

  /// The open folder's tile well in the library, which its panel grows out
  /// of and shrinks back into; null when it was opened from elsewhere.
  Rect? _from;

  final _panelFocus = FocusNode(debugLabel: 'library folder');
  final _stack = GlobalKey();
  final _panelSites = <SiteId, GlobalKey>{};

  /// What the home grid shows: browsing or searching, and whether a search
  /// found nothing. Its icons' keys start afresh with each, since the grid
  /// it leaves still fades out holding the old ones.
  (bool, bool)? _mode;
  var _groupTiles = <WebspaceId, GlobalKey>{};
  var _foundSites = <SiteId, GlobalKey>{};

  /// Opens the selected webspace's folder.
  void openFolder() {
    if (_open) return;
    setState(() => _open = true);
    _run(forward: true);
    // Into the panel, so Escape and the keyboard reach it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _panelFocus.requestFocus();
    });
  }

  /// Closes the open folder; false when none was open. The page's Back
  /// calls it first, so one owner decides what Back does.
  bool closeFolder() {
    if (!_open) return false;
    _from = _groupWell(widget.selectedWebspaceId) ?? _from;
    setState(() => _open = false);
    _run(forward: false);
    return true;
  }

  void _run({required bool forward}) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _panel.value = forward ? 1 : 0;
    } else {
      unawaited(forward ? _panel.forward() : _panel.reverse());
    }
  }

  @override
  void initState() {
    super.initState();
    _panel = AnimationController(
      vsync: this,
      duration: Motion.launch,
      reverseDuration: Motion.launchBack,
    )..addStatusListener(_panelSettled);
    _growth = CurvedAnimation(
      parent: _panel,
      curve: Motion.launchCurve,
      reverseCurve: Motion.launchCurve.flipped,
    );
  }

  void _panelSettled(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  /// Where [site]'s icon is on screen, in global coordinates: in the open
  /// folder, else among the search results; null where it is not in view.
  Rect? siteWell(SiteId site) {
    final context = (_open ? _panelSites : _foundSites)[site]?.currentContext;
    final tile = context?.findRenderObject();
    if (context == null || tile is! RenderBox || !tile.hasSize) return null;
    final well = SiteGridTile.wellIn(
      tile.localToGlobal(Offset.zero) & tile.size,
    );
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (viewport is RenderBox &&
        !(viewport.localToGlobal(Offset.zero) & viewport.size).contains(
          well.center,
        )) {
      return null;
    }
    return well;
  }

  Rect? _groupWell(WebspaceId? id) {
    final tile = _groupTiles[id]?.currentContext?.findRenderObject();
    final stack = _stack.currentContext?.findRenderObject();
    if (tile is! RenderBox || stack is! RenderBox || !tile.hasSize) {
      return null;
    }
    return WebspaceGroupTile.wellIn(
      tile.localToGlobal(Offset.zero, ancestor: stack) & tile.size,
    );
  }

  @override
  void didUpdateWidget(WebspaceLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected == null && !_panel.isDismissed) {
      _open = false;
      _panel.value = 0;
    }
  }

  @override
  void dispose() {
    _panelFocus.dispose();
    _growth.dispose();
    _panel.dispose();
    _search.dispose();
    super.dispose();
  }

  Webspace? get _selected => widget.webspaces
      .where((w) => w.id == widget.selectedWebspaceId)
      .firstOrNull;

  List<int> _order(WebspaceId? id) =>
      WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: id,
        webspaces: widget.webspaces,
        siteCount: widget.sites.length,
      );

  int _tabCount(List<int> order) => [
    for (final i in order)
      if (widget.showsTabCount(widget.sites[i])) widget.sites[i].tabs.length,
  ].fold(0, (sum, n) => sum + n);

  int _siteColumns(BuildContext context, {required double width}) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return ((width - Spacing.lg * 2 + Spacing.sm) /
            (LibraryStyle.tileMinWidth * math.max(1, scale * .7) + Spacing.sm))
        .floor()
        .clamp(1, 7);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final webspace = _selected;
    final panelShown = webspace != null && (_open || !_panel.isDismissed);
    // Back is the page's to handle: it closes the folder through closeFolder.
    return PopScope(
      canPop: widget.currentSite != null || !_open,
      child: Material(
        color: LibraryStyle.background(theme.brightness),
        child: Stack(
          key: _stack,
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: _open,
              child: ExcludeSemantics(
                excluding: panelShown,
                child: _home(context),
              ),
            ),
            if (panelShown)
              LayoutBuilder(
                builder: (context, constraints) => AnimatedBuilder(
                  animation: _growth,
                  builder: (context, _) => _panelLayer(
                    context,
                    webspace: webspace,
                    size: constraints.biggest,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _home(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final tabs = _tabCount(_order(WebspaceId.all));
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: LibraryStyle.maxWidth),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                Spacing.lg,
                Spacing.md,
                Spacing.sm,
                Spacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      loc.libraryWebspaces,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontSize: LibraryStyle.titleSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.7,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: loc.webspacesListCreateButton,
                    onPressed: widget.onAddWebspace,
                    icon: const Icon(Icons.add),
                    color: theme.colorScheme.primary,
                  ),
                  if (tabs > 0)
                    TabCountButton(
                      count: tabs,
                      onPressed: () => widget.onShowTabs(WebspaceId.all),
                    ),
                  IconButton(
                    tooltip: loc.homeAppSettingsTooltip,
                    onPressed: () =>
                        unawaited(_settings.run(widget.onOpenSettings)),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.sm,
              ),
              child: TextField(
                key: const ValueKey('library-search'),
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: loc.librarySearchWebspaces,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: loc.commonClose,
                          onPressed: () {
                            _search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close),
                        ),
                  filled: true,
                  fillColor: LibraryStyle.field(theme.brightness),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.xl),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.xl),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(Spacing.lg),
                ),
              ),
            ),
            Expanded(child: _groups(context)),
          ],
        ),
      ),
    );
  }

  /// The open folder: a panel over the blurred, dimmed grid, which grows out
  /// of the folder's tile and shrinks back into it.
  Widget _panelLayer(
    BuildContext context, {
    required Webspace webspace,
    required Size size,
  }) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final t = _growth.value;
    final shown = t.clamp(0.0, 1.0);
    final target = _panelRect(
      context,
      size: size,
      count: _order(webspace.id).length,
    );
    final from =
        _from ??
        Rect.fromCenter(
          center: target.center,
          width: LibraryStyle.siteWell,
          height: LibraryStyle.siteWell,
        );
    return IgnorePointer(
      ignoring: !_open,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              label: loc.commonClose,
              button: true,
              onTap: closeFolder,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: closeFolder,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: LibraryStyle.scrimBlur * shown,
                    sigmaY: LibraryStyle.scrimBlur * shown,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: LibraryStyle.scrimOpacity * shown,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: Rect.lerp(from, target, t)!,
            child: Focus(
              focusNode: _panelFocus,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent ||
                    event.logicalKey != LogicalKeyboardKey.escape) {
                  return KeyEventResult.ignored;
                }
                closeFolder();
                return KeyEventResult.handled;
              },
              child: Semantics(
                scopesRoute: true,
                namesRoute: true,
                explicitChildNodes: true,
                label: webspace.name,
                // Taps on the panel's empty parts stay on the panel.
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  child: Material(
                    key: const ValueKey('library-folder'),
                    color: Color.lerp(
                      LibraryStyle.group(theme.brightness, id: webspace.id),
                      LibraryStyle.panel(theme.brightness),
                      shown,
                    ),
                    elevation: Elevations.floatingActive * shown,
                    borderRadius: BorderRadius.circular(
                      lerpDouble(
                        LibraryStyle.radius,
                        LibraryStyle.panelRadius,
                        shown,
                      )!,
                    ),
                    clipBehavior: Clip.antiAlias,
                    // The folder's content scales with the panel, as a
                    // phone's folder grows out of its preview, rather than
                    // being cut by it.
                    child: FittedBox(
                      child: SizedBox.fromSize(
                        size: target.size,
                        child: Opacity(
                          opacity: ((t - .15) / .5).clamp(0.0, 1.0),
                          child: _folder(context, webspace: webspace),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Centered, as wide as a phone's folder, and as tall as its sites need
  /// up to most of the screen.
  Rect _panelRect(
    BuildContext context, {
    required Size size,
    required int count,
  }) {
    final insets = MediaQuery.paddingOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final width = math.min(
      size.width - Spacing.lg * 2,
      LibraryStyle.panelMaxWidth,
    );
    final rows = math.max(
      1,
      (count / _siteColumns(context, width: width)).ceil(),
    );
    final header =
        Spacing.lg +
        math.max(
          kMinInteractiveDimension,
          scaler.scale(22) * 1.3 + scaler.scale(12) * 1.4,
        );
    final grid =
        rows *
            SiteGridTile.extentFor(
              context,
              well: LibraryStyle.siteWell,
              webspaceCount: 0,
            ) +
        (rows - 1) * Spacing.lg +
        Spacing.lg * 2;
    final room = size.height - insets.vertical - Spacing.xl * 2;
    final height = math.min(header + grid, room);
    return Rect.fromLTWH(
      (size.width - width) / 2,
      insets.top + (size.height - insets.vertical - height) / 2,
      width,
      height,
    );
  }

  Widget _folder(BuildContext context, {required Webspace webspace}) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final order = _order(webspace.id);
    final tabs = _tabCount(order);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            Spacing.xl,
            Spacing.lg,
            Spacing.sm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      webspace.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      loc.webspacesListSiteCount(order.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: loc.homeAddSite,
                onPressed: widget.onAddSite,
                icon: const Icon(Icons.add),
                color: theme.colorScheme.primary,
              ),
              if (tabs > 0)
                TabCountButton(
                  count: tabs,
                  onPressed: () => widget.onShowTabs(webspace.id),
                ),
            ],
          ),
        ),
        Expanded(
          child: order.isEmpty
              ? _empty(context, message: loc.homeNoSitesInWebspace)
              : LayoutBuilder(
                  builder: (context, constraints) => CustomScrollView(
                    key: PageStorageKey(('library-folder', webspace.id)),
                    slivers: [
                      _siteGrid(
                        context,
                        width: constraints.maxWidth,
                        order: order,
                        shown: order,
                        keys: _panelSites,
                        memberships: false,
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// The groups, or what a search finds; going between browsing, results
  /// and none crossfades, and icons a search keeps slide to their places.
  Widget _groups(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final query = _search.text.trim().toLowerCase();
    final shown = widget.webspaces
        .where((w) => w.name.toLowerCase().contains(query))
        .toList();
    final order = _order(WebspaceId.all);
    final matchingSites = query.isEmpty ? <int>[] : _matchingSites(order);
    final none = shown.isEmpty && matchingSites.isEmpty;
    final mode = (query.isEmpty, none);
    if (mode != _mode) {
      _mode = mode;
      _groupTiles = {};
      _foundSites = {};
    }
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.reveal,
      child: KeyedSubtree(
        key: ValueKey(mode),
        child: none
            ? _empty(
                context,
                message: query.isNotEmpty
                    ? loc.libraryNoResults
                    : loc.webspacesListEmpty,
              )
            : _found(
                context,
                query: query,
                shown: shown,
                order: order,
                matchingSites: matchingSites,
              ),
      ),
    );
  }

  Widget _found(
    BuildContext context, {
    required String query,
    required List<Webspace> shown,
    required List<int> order,
    required List<int> matchingSites,
  }) {
    final loc = AppLocalizations.of(context);
    final reorder = query.isEmpty ? widget.onReorder : null;
    // This grid's own keys: it builds icons lazily while a crossfade fades
    // it out, after the next grid has taken fresh ones.
    final tiles = _groupTiles;
    final found = _foundSites;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final minimum =
            LibraryStyle.tileMinWidth * math.max(1, scaler.scale(1) * .7);
        final columns =
            ((constraints.maxWidth - Spacing.lg * 2 + Spacing.sm) /
                    (minimum + Spacing.sm))
                .floor()
                .clamp(1, 4);
        return CustomScrollView(
          key: const PageStorageKey('webspace-groups'),
          slivers: [
            if (query.isNotEmpty && shown.isNotEmpty)
              _searchHeading(context, label: loc.libraryWebspaces),
            if (shown.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.xl,
                  Spacing.lg,
                  Spacing.xl,
                ),
                sliver: LauncherGrid<WebspaceId>(
                  order: [for (final w in shown) w.id],
                  fixed: (id) => id == WebspaceId.all,
                  onMove: reorder == null
                      ? null
                      : (id, {required to}) =>
                            _moveGroup(id, to: to, reorder: reorder),
                  builder: (context, {required places}) => SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: Spacing.sm,
                      mainAxisSpacing: Spacing.xl,
                      mainAxisExtent: WebspaceGroupTile.extentFor(
                        textScaler: scaler,
                        textTheme: Theme.of(context).textTheme,
                        well: LibraryStyle.siteWell,
                      ),
                    ),
                    itemCount: places.length,
                    findChildIndexCallback: (key) {
                      final at = key is ValueKey
                          ? places.indexOf(key.value)
                          : -1;
                      return at < 0 ? null : at;
                    },
                    itemBuilder: (context, index) {
                      final webspace = shown.firstWhere(
                        (w) => w.id == places[index],
                      );
                      return KeyedSubtree(
                        key: ValueKey(webspace.id),
                        child: LauncherCell<WebspaceId>(
                          index: index,
                          child: LauncherSlot(
                            child: WebspaceGroupTile(
                              key: tiles.putIfAbsent(
                                webspace.id,
                                GlobalKey.new,
                              ),
                              webspace: webspace,
                              sites: [
                                for (final i in _order(webspace.id))
                                  widget.sites[i],
                              ],
                              selected:
                                  webspace.id == widget.selectedWebspaceId,
                              onOpen: () {
                                FocusScope.of(context).unfocus();
                                _from = _groupWell(webspace.id);
                                widget.onSelectWebspace(webspace);
                              },
                              onMenu: (at) =>
                                  unawaited(_menu(webspace, at: at)),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (matchingSites.isNotEmpty) ...[
              _searchHeading(context, label: loc.librarySites),
              _siteGrid(
                context,
                width: constraints.maxWidth,
                order: order,
                shown: matchingSites,
                keys: found,
                memberships: true,
              ),
            ],
          ],
        );
      },
    );
  }

  /// [id] dragged to place [to] of the groups, which only reorder while no
  /// search filters them; "All" stays first.
  void _moveGroup(
    WebspaceId id, {
    required int to,
    required void Function(int from, {required int newIndex}) reorder,
  }) {
    final from = widget.webspaces.indexWhere((w) => w.id == id);
    if (from <= 0 || to <= 0 || from == to) return;
    reorder(from, newIndex: to > from ? to + 1 : to);
  }

  Widget _searchHeading(BuildContext context, {required String label}) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(label, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
      );

  List<int> _matchingSites(List<int> order) {
    final query = _search.text.trim().toLowerCase();
    return order
        .where(
          (i) =>
              widget.sites[i].getDisplayName().toLowerCase().contains(query) ||
              widget.sites[i].initUrl.toLowerCase().contains(query),
        )
        .toList();
  }

  /// [shown] of [order] as icons, each under a key in [keys] so its well can
  /// be found; [memberships] labels each with the named webspaces it is in,
  /// as search results across webspaces are, which do not reorder.
  Widget _siteGrid(
    BuildContext context, {
    required double width,
    required List<int> order,
    required List<int> shown,
    required Map<SiteId, GlobalKey> keys,
    required bool memberships,
  }) {
    final labels = {
      for (final i in shown)
        i: memberships
            ? widget.webspaces
                  .where(
                    (w) =>
                        !w.isAll && w.siteIds.contains(widget.sites[i].siteId),
                  )
                  .toList()
            : const <Webspace>[],
    };
    final reorder = !memberships && order.length > 1
        ? widget.onReorderSite
        : null;
    final onReorder = reorder;
    return SliverPadding(
      padding: const EdgeInsets.all(Spacing.lg),
      sliver: LauncherGrid<int>(
        order: [for (final i in shown) order.indexOf(i)],
        fixed: (_) => false,
        onMove: onReorder == null
            ? null
            : (from, {required to}) => onReorder(from, to: to),
        builder: (context, {required places}) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _siteColumns(context, width: width),
            crossAxisSpacing: Spacing.sm,
            mainAxisSpacing: Spacing.lg,
            mainAxisExtent: shown
                .map(
                  (i) => SiteGridTile.extentFor(
                    context,
                    well: LibraryStyle.siteWell,
                    webspaceCount: labels[i]!.length,
                  ),
                )
                .reduce(math.max),
          ),
          itemCount: places.length,
          findChildIndexCallback: (key) {
            final at = places.indexWhere(
              (p) => identical(keys[widget.sites[order[p]].siteId], key),
            );
            return at < 0 ? null : at;
          },
          itemBuilder: (context, index) {
            final i = order[places[index]];
            final site = widget.sites[i];
            return KeyedSubtree(
              key: keys.putIfAbsent(site.siteId, GlobalKey.new),
              child: LauncherCell<int>(
                index: index,
                child: LauncherSlot(
                  child: SiteGridTile(
                    key: ValueKey(site.siteId),
                    site: site,
                    listIndex: places[index],
                    selected: identical(site, widget.currentSite),
                    showTabCount:
                        widget.showsTabCount(site) && site.tabs.length > 1,
                    layout: SiteGridTileLayout.library,
                    webspaces: labels[i]!,
                    onOpen: () {
                      FocusScope.of(context).unfocus();
                      widget.onOpenSite(site);
                    },
                    onMenu: (context, {required globalPosition}) =>
                        widget.onSiteMenu(
                          context,
                          site: site,
                          position: globalPosition,
                        ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, {required String message}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );

  Future<void> _menu(Webspace webspace, {required Offset at}) async {
    final loc = AppLocalizations.of(context);
    final action = await showLauncherMenu<_GroupAction>(
      context,
      position: at,
      items: [
        (
          value: _GroupAction.edit,
          icon: Icons.edit,
          label: loc.commonEdit,
          destructive: false,
        ),
        if (!webspace.isAll)
          (
            value: _GroupAction.delete,
            icon: Icons.delete,
            label: loc.commonDelete,
            destructive: true,
          ),
      ],
    );
    if (!mounted || !widget.webspaces.contains(webspace)) return;
    switch (action) {
      case _GroupAction.edit:
        widget.onEditWebspace(webspace);
      case _GroupAction.delete:
        widget.onDeleteWebspace(webspace);
      case null:
        return;
    }
  }
}
