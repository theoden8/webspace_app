import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PointerDeviceKind, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/library_layout.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/launcher_grid.dart';
import 'package:webspace/widgets/launcher_row.dart';
import 'package:webspace/widgets/launcher_slot.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_list_menu.dart';
import 'package:webspace/widgets/accent_logo.dart';
import 'package:webspace/widgets/tab_count_pill.dart';
import 'package:webspace/widgets/webspace_name.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

enum _GroupAction { edit, delete, moveUp, moveDown }

enum _AddAction { site, webspace }

/// A grid of site icons: a folder's page, laid out as rows or a grid as every
/// folder is and reordered where it is the selected webspace's, or search
/// results across webspaces, each labelled with the webspaces it is in.
sealed class _SiteGridOf {
  const _SiteGridOf();
}

final class _FolderPage extends _SiteGridOf {
  const _FolderPage({required this.reorders, required this.placing});

  final bool reorders;

  /// Where the page's sites stand on the way between two layouts.
  final _Placing placing;
}

final class _SearchResults extends _SiteGridOf {
  const _SearchResults();
}

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
    required this.accentColor,
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

  /// A new site, started in the webspace [into] it is added from; null from
  /// the home screen, where it starts in none but All (EDIT-012).
  final void Function({required WebspaceId? into}) onAddSite;

  /// The tab tree of every site [scope] holds: all sites from the home
  /// header, the open folder's from its panel.
  final void Function(WebspaceId scope) onShowTabs;
  final Future<void> Function() onOpenSettings;

  /// The accent the app's logo in the home's title takes.
  final AccentColor accentColor;

  @override
  State<WebspaceLibrary> createState() => WebspaceLibraryState();
}

/// Owns the open folder and the search without changing saved app state.
class WebspaceLibraryState extends State<WebspaceLibrary>
    with TickerProviderStateMixin {
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

  /// Each folder page's icons' keys: one site can sit on several pages.
  final _panelSites = <WebspaceId, Map<SiteId, GlobalKey>>{};

  /// How far the open folder's top bar is pulled down, which the panel
  /// follows; it springs back to 0 when let go short of closing.
  late final AnimationController _pull;

  /// The open panel's height at its last layout, which a pull is measured in.
  double _panelHeight = 0;

  /// How the folders lay out their sites, and apart from them how the home
  /// lays out the webspaces (WEBSPACE-015).
  late final _Layout _folderLayout;
  late final _Layout _homeLayout;

  /// What an open folder has room for, and how far the home's webspaces
  /// have turned into rows, at their last layout.
  LibraryRoom? _folderRoom;
  double _homeList = 0;

  /// The open folder's pages, one per webspace in the grid's order, as a
  /// phone's home screen has pages: made on the selected webspace's page
  /// when a folder opens, and let go when it has closed.
  PageController? _pages;

  /// The page a dot or an arrow last asked for, until the pages come to rest,
  /// so a second press goes one further rather than to the same page.
  int? _aim;

  /// What the home grid shows: browsing or searching, and whether a search
  /// found nothing. Its icons' keys start afresh with each, since the grid
  /// it leaves still fades out holding the old ones.
  (bool, bool)? _mode;
  var _groupTiles = <WebspaceId, GlobalKey>{};
  var _foundSites = <SiteId, GlobalKey>{};

  /// The sites another shows the same icon as, worked out once a build rather
  /// than on every frame a folder moves.
  Set<SiteId> _lookalikes = const {};

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
    _pull = AnimationController.unbounded(vsync: this);
    bool still() => MediaQuery.disableAnimationsOf(context);
    _folderLayout = _Layout(
      pref: AppPref.libraryLayout,
      vsync: this,
      still: still,
    );
    _homeLayout = _Layout(
      pref: AppPref.libraryWebspaceLayout,
      vsync: this,
      still: still,
    );
    _growth = CurvedAnimation(
      parent: _panel,
      curve: Motion.launchCurve,
      reverseCurve: Motion.launchCurve.flipped,
    );
  }

  void _panelSettled(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !mounted) return;
    _pages?.dispose();
    _pages = null;
    _aim = null;
    _pull.value = 0;
    setState(() {});
  }

  /// Where [site]'s icon is on screen, in global coordinates: in the open
  /// folder, else among the search results; null where it is not in view.
  Rect? siteWell(SiteId site) {
    final keys = _open ? _panelSites[widget.selectedWebspaceId] : _foundSites;
    final context = keys?[site]?.currentContext;
    final tile = context?.findRenderObject();
    if (context == null || tile is! RenderBox || !tile.hasSize) return null;
    final room = _folderRoom;
    final well = SiteGridTile.wellIn(
      tile.localToGlobal(Offset.zero) & tile.size,
      list: _open && room != null
          ? _folderLayout
                .placing(
                  count: _order(widget.selectedWebspaceId).length,
                  room: room,
                )
                .list
          : 0,
      direction: Directionality.of(context),
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
      list: _homeList,
      direction: Directionality.of(context),
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
    _pages?.dispose();
    _panelFocus.dispose();
    _growth.dispose();
    _panel.dispose();
    _pull.dispose();
    _folderLayout.dispose();
    _homeLayout.dispose();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _lookalikes = sitesSharingAnIcon(widget.sites);
    final webspace = _selected;
    final panelShown = webspace != null && (_open || !_panel.isDismissed);
    final pages = panelShown
        ? _pages ??= PageController(
            initialPage: widget.webspaces.indexOf(webspace),
          )
        : null;
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
              child: ExcludeFocus(
                excluding: _open,
                child: ExcludeSemantics(
                  excluding: panelShown,
                  child: _home(context),
                ),
              ),
            ),
            if (pages != null)
              LayoutBuilder(
                builder: (context, constraints) => AnimatedBuilder(
                  animation: Listenable.merge([
                    _growth,
                    pages,
                    _pull,
                    _folderLayout.animation,
                  ]),
                  builder: (context, _) => _panelLayer(
                    context,
                    webspace: webspace!,
                    pages: pages,
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
                  AccentLogo(
                    accentColor: widget.accentColor,
                    size: LibraryStyle.logoSize,
                    brightness: theme.brightness,
                  ),
                  const SizedBox(width: Spacing.sm),
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
                  Builder(
                    builder: (button) => IconButton(
                      tooltip: loc.commonAdd,
                      onPressed: () => unawaited(_add(button)),
                      icon: const Icon(Icons.add),
                      color: theme.colorScheme.primary,
                    ),
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
              child: Row(
                children: [
                  Expanded(child: _searchField(context)),
                  const SizedBox(width: Spacing.sm),
                  _LayoutSwitch(layout: _homeLayout),
                ],
              ),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: _homeLayout.animation,
                builder: (context, _) => _groups(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    return TextField(
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
              );
  }

  /// The open folder: a panel over the blurred, dimmed grid, which grows out
  /// of the folder's tile and shrinks back into it.
  Widget _panelLayer(
    BuildContext context, {
    required Webspace webspace,
    required PageController pages,
    required Size size,
  }) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final t = _growth.value;
    final shown = t.clamp(0.0, 1.0);
    final last = widget.webspaces.length - 1;
    final page =
        (pages.hasClients ? pages.page : null) ?? pages.initialPage.toDouble();
    final lower = page.floor().clamp(0, last);
    final upper = page.ceil().clamp(0, last);
    final room = _folderRoom = _folderLevel(context, labels: 0).room(
      width: _panelWidth(size),
      height: _folderHeight(context, size: size),
    );
    Rect sized(int index) {
      final count = _order(widget.webspaces[index].id).length;
      return _panelRect(
        context,
        size: size,
        count: count,
        placing: _folderLayout.placing(count: count, room: room),
      );
    }
    // A swipe keeps the size of the page it leaves, the selected one, until
    // late in its way to the next, then takes that page's.
    final ahead = page >= widget.webspaces.indexOf(webspace);
    final leaving = ahead ? lower : upper;
    final target = Rect.lerp(
      sized(leaving),
      sized(ahead ? upper : lower),
      Motion.folderPageResize.transform((page - leaving).abs().clamp(0, 1)),
    )!;
    _panelHeight = target.height;
    // Pulled down by its top bar, the panel follows the finger, giving up a
    // little size and the dimming of the grid behind it.
    final pulled = (_pull.value / target.height).clamp(0.0, 1.0);
    final held = Rect.fromCenter(
      center: target.center + Offset(0, _pull.value),
      width: target.width * (1 - LibraryStyle.pullShrink * pulled),
      height: target.height * (1 - LibraryStyle.pullShrink * pulled),
    );
    final dim = shown * (1 - pulled);
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
                    sigmaX: LibraryStyle.scrimBlur * dim,
                    sigmaY: LibraryStyle.scrimBlur * dim,
                  ),
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: LibraryStyle.scrimOpacity * dim,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fromRect(
            rect: Rect.lerp(from, held, t)!,
            child: Focus(
              focusNode: _panelFocus,
              // Focus starts here when a folder opens; a move between its
              // icons never lands on the panel around them.
              skipTraversal: true,
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey == LogicalKeyboardKey.escape) {
                  closeFolder();
                  return KeyEventResult.handled;
                }
                // A move down or up from the panel itself goes into it, to
                // its header and then its icons: nothing is below or above
                // the panel to move to, so it would stop there (NAV-016).
                if (_panelFocus.hasPrimaryFocus &&
                    (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                        event.logicalKey == LogicalKeyboardKey.arrowUp)) {
                  final first = _panelFocus.traversalDescendants.firstOrNull;
                  first?.requestFocus();
                  return first == null
                      ? KeyEventResult.ignored
                      : KeyEventResult.handled;
                }
                // Arrows turn pages only while no icon in the panel has
                // focus: there they move the focus between icons.
                final rtl = Directionality.of(context) == TextDirection.rtl;
                final step = switch (event.logicalKey) {
                  LogicalKeyboardKey.arrowRight => rtl ? -1 : 1,
                  LogicalKeyboardKey.arrowLeft => rtl ? 1 : -1,
                  _ => 0,
                };
                if (step == 0 || !_panelFocus.hasPrimaryFocus) {
                  return KeyEventResult.ignored;
                }
                _turnTo(
                  context,
                  pages: pages,
                  index: ((_aim ?? page.round()) + step).clamp(
                    0,
                    widget.webspaces.length - 1,
                  ),
                );
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
                          child: _folderPages(
                            context,
                            pages: pages,
                            page: page,
                          ),
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

  /// An open folder's width in a library of [size].
  double _panelWidth(Size size) =>
      math.min(size.width - Spacing.lg * 2, LibraryStyle.panelMaxWidth);

  /// An open folder's top bar's height.
  double _panelHeader(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Spacing.lg +
        math.max(
          kMinInteractiveDimension,
          scaler.scale(22) * 1.3 + scaler.scale(12) * 1.4,
        );
  }

  /// The most an open folder may be tall in a library of [size].
  double _panelRoom(BuildContext context, {required Size size}) =>
      size.height - MediaQuery.paddingOf(context).vertical - Spacing.xl * 2;

  /// How tall an open folder's sites may be in a library of [size].
  double _folderHeight(BuildContext context, {required Size size}) =>
      _panelRoom(context, size: size) -
      _panelHeader(context) -
      (widget.webspaces.length > 1 ? LibraryStyle.pageDots : 0);

  /// A folder's sites as a level, each icon over as many webspace [labels]
  /// as the most any of them has.
  _Level _folderLevel(BuildContext context, {required int labels}) => _Level(
    rowExtent: LauncherMorphTile.rowExtentFor(context),
    iconExtent: (column) =>
        SiteGridTile.extentFor(context, width: column, webspaceCount: labels),
    iconColumnMin: LibraryStyle.iconColumnMin(MediaQuery.textScalerOf(context)),
    fill: LibraryStyle.packedFillOf(MediaQuery.sizeOf(context)),
    icons: const (
      padding: EdgeInsets.all(Spacing.lg),
      across: Spacing.sm,
      down: Spacing.lg,
    ),
    rows: const (
      padding: EdgeInsets.all(Spacing.sm),
      across: Spacing.sm,
      down: 0,
    ),
  );

  /// Centered, as wide as a phone's folder, and as tall as its [count]
  /// sites need, as [placing] has them, up to most of the screen.
  Rect _panelRect(
    BuildContext context, {
    required Size size,
    required int count,
    required _Placing placing,
  }) {
    final insets = MediaQuery.paddingOf(context);
    final width = _panelWidth(size);
    final level = _folderLevel(context, labels: 0);
    double tall(LibraryPlacement placement) =>
        level.height(placement, count: math.max(1, count), width: width);
    final dots = widget.webspaces.length > 1 ? LibraryStyle.pageDots : 0;
    final height = math.min(
      _panelHeader(context) +
          lerpDouble(tall(placing.from), tall(placing.to), placing.at)! +
          dots,
      _panelRoom(context, size: size),
    );
    return Rect.fromLTWH(
      (size.width - width) / 2,
      insets.top + (size.height - insets.vertical - height) / 2,
      width,
      height,
    );
  }

  /// The open folder's pages: a swipe goes to the next or previous
  /// webspace, which becomes the selected one, and the dots under them go
  /// straight to one (WEBSPACE-008).
  Widget _folderPages(
    BuildContext context, {
    required PageController pages,
    required double page,
  }) {
    final theme = Theme.of(context);
    final on = page.round();
    return Column(
      children: [
        Expanded(
          // A page is selected where a swipe comes to rest, not as it
          // passes halfway: a switch unloads the sites it leaves.
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (end) {
              if (end.depth == 0) _landed(pages);
              return false;
            },
            child: PageView.builder(
              controller: pages,
              // Flutter leaves the mouse out of drag scrolling; a desktop
              // pages through folders with it as a phone does with a finger.
              scrollBehavior: ScrollConfiguration.of(context).copyWith(
                scrollbars: false,
                dragDevices: PointerDeviceKind.values.toSet(),
              ),
              itemCount: widget.webspaces.length,
              itemBuilder: (context, index) =>
                  _folder(context, webspace: widget.webspaces[index]),
            ),
          ),
        ),
        if (widget.webspaces.length > 1)
          SizedBox(
            height: LibraryStyle.pageDots,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                children: [
                  for (final (index, webspace) in widget.webspaces.indexed)
                    Semantics(
                      button: true,
                      selected: index == on,
                      label: webspace.name,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            _turnTo(context, pages: pages, index: index),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.xs + Spacing.xs / 2,
                            vertical: Spacing.sm + Spacing.xs / 2,
                          ),
                          child: AnimatedContainer(
                            duration: Motion.press,
                            width: index == on
                                ? LibraryStyle.pageDot * 2.5
                                : LibraryStyle.pageDot,
                            height: LibraryStyle.pageDot,
                            decoration: BoxDecoration(
                              color: index == on
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant
                                        .withAlpha(90),
                              borderRadius: BorderRadius.circular(
                                LibraryStyle.pageDot / 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// The top bar let go after a pull closes the folder into its tile where
  /// [LibraryStyle.pullCloses] says so; short of that the panel springs back.
  void _letGo({required double velocity}) {
    if (LibraryStyle.pullCloses(
      pulled: _pull.value,
      extent: _panelHeight,
      velocity: velocity,
    )) {
      closeFolder();
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _pull.value = 0;
      return;
    }
    unawaited(
      _pull.animateTo(0, duration: Motion.settle, curve: Motion.launchCurve),
    );
  }

  /// Goes to page [index] of the open folder, as a dot or an arrow key asks.
  void _turnTo(
    BuildContext context, {
    required PageController pages,
    required int index,
  }) {
    _aim = index;
    if (MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(index);
      return;
    }
    unawaited(
      pages.animateToPage(
        index,
        duration: Motion.settle,
        curve: Motion.launchCurve,
      ),
    );
  }

  /// The webspace whose page a swipe or a dot came to rest on becomes the
  /// selected one, as a tap on its folder would make it.
  void _landed(PageController pages) {
    _aim = null;
    final at = pages.page?.round();
    if (at == null || at < 0 || at >= widget.webspaces.length) return;
    final webspace = widget.webspaces[at];
    if (webspace.id != widget.selectedWebspaceId) {
      widget.onSelectWebspace(webspace);
    }
  }

  Widget _folder(BuildContext context, {required Webspace webspace}) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final order = _order(webspace.id);
    final tabs = _tabCount(order);
    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (details) =>
              _pull.value = math.max(0, _pull.value + details.delta.dy),
          onVerticalDragEnd: (details) =>
              _letGo(velocity: details.primaryVelocity ?? 0),
          child: Padding(
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
                      WebspaceName(
                        webspace,
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
                _LayoutSwitch(layout: _folderLayout),
                IconButton(
                  tooltip: loc.homeAddSite,
                  onPressed: () => widget.onAddSite(into: webspace.id),
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
                        keys: _panelSites.putIfAbsent(webspace.id, () => {}),
                        of: _FolderPage(
                          reorders: webspace.id == widget.selectedWebspaceId,
                          placing: _folderLayout.placing(
                            count: order.length,
                            room: _folderRoom!,
                          ),
                        ),
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
        final width = constraints.maxWidth;
        final level = _Level(
          rowExtent: LauncherMorphTile.rowExtentFor(context),
          iconExtent: (column) => WebspaceGroupTile.extentFor(
            textScaler: scaler,
            textTheme: Theme.of(context).textTheme,
            width: column,
          ),
          iconColumnMin: LibraryStyle.iconColumnMin(scaler),
          fill: LibraryStyle.packedFillOf(MediaQuery.sizeOf(context)),
          // Rows run the width, their wells under the title's start.
          icons: const (
            padding: EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.xl,
              Spacing.lg,
              Spacing.xl,
            ),
            across: Spacing.sm,
            down: Spacing.xl,
          ),
          rows: const (
            padding: EdgeInsets.symmetric(vertical: Spacing.sm),
            across: 0,
            down: 0,
          ),
        );
        final placing = _homeLayout.placing(
          count: shown.length,
          room: level.room(width: width, height: constraints.maxHeight),
        );
        final list = _homeList = placing.list;
        return CustomScrollView(
          key: const PageStorageKey('webspace-groups'),
          slivers: [
            if (query.isNotEmpty && shown.isNotEmpty)
              _searchHeading(context, label: loc.libraryWebspaces),
            if (shown.isNotEmpty)
              SliverPadding(
                padding: level.padding(placing),
                sliver: LauncherGrid<WebspaceId>(
                  order: [for (final w in shown) w.id],
                  fixed: (id) => id == WebspaceId.all,
                  onMove: reorder == null
                      ? null
                      : (id, {required to}) =>
                            _moveGroup(id, to: to, reorder: reorder),
                  builder: (context, {required places}) => SliverGrid.builder(
                    gridDelegate: level.morph(placing, width: width),
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
                            morphing: placing.moving,
                            child: Builder(
                              builder: (cell) => WebspaceGroupTile(
                                key: tiles.putIfAbsent(
                                  webspace.id,
                                  GlobalKey.new,
                                ),
                                list: list,
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
                                onMenu: (at) => unawaited(
                                  _menu(
                                    webspace,
                                    at: at,
                                    moves: LauncherCell.menuMoves(cell),
                                  ),
                                ),
                              ),
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
                of: const _SearchResults(),
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
  /// be found, laid out as what the grid is [of] has them.
  Widget _siteGrid(
    BuildContext context, {
    required double width,
    required List<int> order,
    required List<int> shown,
    required Map<SiteId, GlobalKey> keys,
    required _SiteGridOf of,
  }) {
    final memberships = switch (of) {
      _FolderPage() => false,
      _SearchResults() => true,
    };
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
    final level = _folderLevel(
      context,
      labels: shown.map((i) => labels[i]!.length).reduce(math.max),
    );
    final (reorders, placing) = switch (of) {
      _FolderPage(:final reorders, :final placing) => (reorders, placing),
      // Search results are a grid whatever the folders' layout.
      _SearchResults() => (
        false,
        _Placing.settled(
          LibraryLayout.grid.place(
            count: shown.length,
            room: level.room(width: width, height: 0),
          ),
        ),
      ),
    };
    final list = placing.list;
    final reorder = reorders && order.length > 1 ? widget.onReorderSite : null;
    final onReorder = reorder;
    return SliverPadding(
      padding: level.padding(placing),
      sliver: LauncherGrid<int>(
        order: [for (final i in shown) order.indexOf(i)],
        fixed: (_) => false,
        onMove: onReorder == null
            ? null
            : (from, {required to}) => onReorder(from, to: to),
        builder: (context, {required places}) => SliverGrid.builder(
          gridDelegate: level.morph(placing, width: width),
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
                  morphing: placing.moving,
                  child: SiteGridTile(
                    key: ValueKey(site.siteId),
                    site: site,
                    listIndex: places[index],
                    selected: identical(site, widget.currentSite),
                    showTabCount:
                        widget.showsTabCount(site) && site.tabs.length > 1,
                    layout: SiteGridTileLayout.library,
                    webspaces: labels[i]!,
                    lookalike: _lookalikes.contains(site.siteId),
                    list: list,
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

  /// The home's add button: a site, or a webspace, under [button].
  Future<void> _add(BuildContext button) async {
    final loc = AppLocalizations.of(context);
    final box = button.findRenderObject()! as RenderBox;
    final action = await showLauncherMenu<_AddAction>(
      context,
      position: box.localToGlobal(box.size.bottomCenter(Offset.zero)),
      items: [
        (
          value: _AddAction.site,
          icon: Icons.public,
          label: loc.homeAddSite,
          destructive: false,
        ),
        (
          value: _AddAction.webspace,
          icon: Icons.create_new_folder_outlined,
          label: loc.webspacesListCreateButton,
          destructive: false,
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _AddAction.site:
        widget.onAddSite(into: null);
      case _AddAction.webspace:
        widget.onAddWebspace();
      case null:
        return;
    }
  }

  /// A webspace's menu; where a remote drives the device, it offers the
  /// [moves] its grid makes, which a drag makes elsewhere.
  Future<void> _menu(
    Webspace webspace, {
    required Offset at,
    required LauncherMoves? moves,
  }) async {
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
        if (moves?.earlier != null)
          (
            value: _GroupAction.moveUp,
            icon: Icons.arrow_upward,
            label: loc.homeMoveUp,
            destructive: false,
          ),
        if (moves?.later != null)
          (
            value: _GroupAction.moveDown,
            icon: Icons.arrow_downward,
            label: loc.homeMoveDown,
            destructive: false,
          ),
      ],
    );
    if (!mounted || !widget.webspaces.contains(webspace)) return;
    switch (action) {
      case _GroupAction.edit:
        widget.onEditWebspace(webspace);
      case _GroupAction.delete:
        widget.onDeleteWebspace(webspace);
      case _GroupAction.moveUp:
        moves?.earlier?.call();
      case _GroupAction.moveDown:
        moves?.later?.call();
      case null:
        return;
    }
  }
}

/// A level's items [at] of the way [from] one placement [to] another.
final class _Placing {
  const _Placing({required this.from, required this.to, required this.at});

  const _Placing.settled(LibraryPlacement placement)
    : from = placement,
      to = placement,
      at = 1;

  final LibraryPlacement from;
  final LibraryPlacement to;
  final double at;

  /// How far the items have turned into rows.
  double get list => lerpDouble(_rows(from), _rows(to), at)!;

  /// Whether the items are on their way, their places moving with the layout
  /// rather than sliding after it.
  bool get moving => at > 0 && at < 1 && from != to;

  static double _rows(LibraryPlacement placement) => switch (placement.form) {
    LibraryForm.rows => 1,
    LibraryForm.icons => 0,
  };
}

/// The padding around a level's items laid out one way, and the gaps between
/// them across and down.
typedef _Spacing = ({EdgeInsets padding, double across, double down});

/// One level of the library as it lays out (WEBSPACE-015): how tall its rows
/// are, how tall its icons are in a column so wide, the narrowest column an
/// icon keeps its whole caption in, the share of its height Automatic fills
/// ([LibraryStyle.packedFillOf]), and how each is spaced.
final class _Level {
  const _Level({
    required this.rowExtent,
    required this.iconExtent,
    required this.iconColumnMin,
    required this.fill,
    required this.icons,
    required this.rows,
  });

  final double rowExtent;
  final double Function(double column) iconExtent;
  final double iconColumnMin;
  final double fill;
  final _Spacing icons;
  final _Spacing rows;

  _Spacing _of(LibraryForm form) => switch (form) {
    LibraryForm.rows => rows,
    LibraryForm.icons => icons,
  };

  double _column(
    LibraryForm form, {
    required int columns,
    required double width,
  }) {
    final spacing = _of(form);
    return (width -
            spacing.padding.horizontal -
            spacing.across * (columns - 1)) /
        columns;
  }

  /// How many columns at least [min] wide fit [width].
  int _fitting(LibraryForm form, {required double min, required double width}) {
    final spacing = _of(form);
    return ((width - spacing.padding.horizontal + spacing.across) /
            (min + spacing.across))
        .floor()
        .clamp(1, LibraryStyle.maxColumns);
  }

  double _extent(LibraryPlacement placement, {required double width}) =>
      switch (placement.form) {
        LibraryForm.rows => rowExtent,
        LibraryForm.icons => iconExtent(
          _column(LibraryForm.icons, columns: placement.columns, width: width),
        ),
      };

  /// What the level has room for, [width] wide and [height] tall.
  LibraryRoom room({required double width, required double height}) {
    final gridColumns = _fitting(
      LibraryForm.icons,
      min: iconColumnMin,
      width: width,
    );
    final rowColumns = _fitting(
      LibraryForm.rows,
      min: LibraryStyle.packedRowMinWidth,
      width: width,
    );
    int tall(LibraryForm form, {required double extent}) {
      final spacing = _of(form);
      return math.max(
        0,
        ((height * fill - spacing.padding.vertical + spacing.down) /
                (extent + spacing.down))
            .floor(),
      );
    }

    return (
      gridColumns: gridColumns,
      rowColumns: rowColumns,
      mostColumns: [
        gridColumns,
        rowColumns,
        LibraryStyle.packedColumns,
      ].reduce(math.max),
      rowsTall: tall(LibraryForm.rows, extent: rowExtent),
      iconsTall: (columns) => tall(
        LibraryForm.icons,
        extent: iconExtent(
          _column(LibraryForm.icons, columns: columns, width: width),
        ),
      ),
    );
  }

  /// Each item's place [placing] has it at, across [width].
  LauncherMorph morph(_Placing placing, {required double width}) =>
      LauncherMorph(
        from: _delegate(placing.from, width: width),
        to: _delegate(placing.to, width: width),
        at: placing.at,
      );

  SliverGridDelegateWithFixedCrossAxisCount _delegate(
    LibraryPlacement placement, {
    required double width,
  }) {
    final spacing = _of(placement.form);
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: placement.columns,
      crossAxisSpacing: spacing.across,
      mainAxisSpacing: spacing.down,
      mainAxisExtent: _extent(placement, width: width),
    );
  }

  /// The padding around the items, [placing] of the way.
  EdgeInsets padding(_Placing placing) => EdgeInsets.lerp(
    _of(placing.from.form).padding,
    _of(placing.to.form).padding,
    placing.at,
  )!;

  /// How tall [count] items are as [placement] has them, padding and all.
  double height(
    LibraryPlacement placement, {
    required int count,
    required double width,
  }) {
    final spacing = _of(placement.form);
    final lines = (count / placement.columns).ceil();
    return spacing.padding.vertical +
        lines * _extent(placement, width: width) +
        math.max(0, lines - 1) * spacing.down;
  }
}

/// How one level of the library lays out its items, following its [pref]
/// (WEBSPACE-015), and the switch from the layout it had to the one it has,
/// which moves rather than jumps unless motion is reduced ([still]).
final class _Layout {
  _Layout({
    required this.pref,
    required TickerProvider vsync,
    required this.still,
  }) : _from = LibraryLayout.of(pref.value),
       _to = LibraryLayout.of(pref.value),
       _switch = AnimationController(
         vsync: vsync,
         duration: Motion.layoutMorph,
         value: 1,
       ) {
    animation = CurvedAnimation(parent: _switch, curve: Motion.layoutCurve);
    pref.listenable.addListener(_changed);
  }

  final AppPref<String> pref;
  final bool Function() still;
  final AnimationController _switch;
  late final CurvedAnimation animation;
  LibraryLayout _from;
  LibraryLayout _to;

  LibraryLayout get mode => _to;

  /// Where [count] items in [room] stand on the way from where the layout
  /// this level had puts them to where the one it has does.
  _Placing placing({required int count, required LibraryRoom room}) => _Placing(
    from: _from.place(count: count, room: room),
    to: _to.place(count: count, room: room),
    at: animation.value,
  );

  /// Where the switch's thumb is, in segments from the first.
  double get thumb =>
      lerpDouble(_from.index, _to.index, animation.value)!;

  void choose(LibraryLayout layout) => unawaited(pref.set(layout.name));

  void _changed() {
    final next = LibraryLayout.of(pref.value);
    if (next == _to) return;
    _from = _to;
    _to = next;
    if (still()) {
      _switch.value = 1;
    } else {
      unawaited(_switch.forward(from: 0));
    }
  }

  void dispose() {
    pref.listenable.removeListener(_changed);
    animation.dispose();
    _switch.dispose();
  }
}

/// A switch between a level of the library's layouts, set app-wide by its
/// [layout]'s pref; its thumb slides as the level turns.
class _LayoutSwitch extends StatelessWidget {
  const _LayoutSwitch({required this.layout});

  final _Layout layout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    const segment = LibraryStyle.layoutSwitchSegment;
    return AnimatedBuilder(
      animation: Listenable.merge([layout.animation, layout.pref.listenable]),
      builder: (context, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Center(
          widthFactor: 1,
          child: Container(
            padding: const EdgeInsets.all(LibraryStyle.layoutSwitchInset),
            decoration: ShapeDecoration(
              color: LibraryStyle.field(theme.brightness),
              shape: const StadiumBorder(),
            ),
            child: Stack(
              children: [
                PositionedDirectional(
                  start: segment.width * layout.thumb,
                  top: 0,
                  width: segment.width,
                  height: segment.height,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: theme.colorScheme.primary,
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in LibraryLayout.values)
                      _segment(
                        theme,
                        option: option,
                        label: switch (option) {
                          LibraryLayout.auto => loc.libraryAutoView,
                          LibraryLayout.grid => loc.libraryGridView,
                          LibraryLayout.list => loc.libraryListView,
                        },
                        icon: switch (option) {
                          LibraryLayout.auto =>
                            Icons.auto_awesome_mosaic_outlined,
                          LibraryLayout.grid => Icons.grid_view_rounded,
                          LibraryLayout.list => Icons.view_agenda_outlined,
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _segment(
    ThemeData theme, {
    required LibraryLayout option,
    required String label,
    required IconData icon,
  }) {
    final on = (1 - (layout.thumb - option.index).abs()).clamp(0.0, 1.0);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: layout.mode == option,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => layout.choose(option),
          child: SizedBox.fromSize(
            size: LibraryStyle.layoutSwitchSegment,
            child: Icon(
              icon,
              size: IconSizes.inline,
              color: Color.lerp(
                theme.colorScheme.onSurfaceVariant,
                theme.colorScheme.onPrimary,
                on,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
