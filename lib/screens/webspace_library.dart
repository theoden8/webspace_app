import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/launcher_item_size.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/launcher_size_picker.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

enum _LibraryView { webspaces, workspace, sites }

enum _GroupAction { edit, delete, resize }

/// A launcher of site groups; navigation and search remain UI-only.
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
    required this.onResizeWebspace,
    required this.onReorder,
    required this.onOpenSite,
    required this.onSiteMenu,
    required this.onReorderSite,
    required this.onAddSite,
    required this.onOpenSettings,
    required this.siteTreeBuilder,
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
  final void Function(Webspace webspace, {required LauncherItemSize size})
  onResizeWebspace;
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
  final Future<void> Function() onOpenSettings;
  final Widget Function(BuildContext context, String query) siteTreeBuilder;

  @override
  State<WebspaceLibrary> createState() => WebspaceLibraryState();
}

/// Owns the library's navigation and search without changing saved app state.
class WebspaceLibraryState extends State<WebspaceLibrary> {
  final _search = TextEditingController();
  _LibraryView _view = _LibraryView.webspaces;
  bool _settingsOpen = false;
  bool _animateNavigation = false;
  double _navigationDirection = 1;

  void showSelectedWebspace() => _show(_LibraryView.workspace);
  void showWebspaces() => _show(_LibraryView.webspaces);

  void _show(_LibraryView view) {
    _search.clear();
    setState(() {
      _animateNavigation =
          (_view == _LibraryView.workspace) != (view == _LibraryView.workspace);
      _navigationDirection = view == _LibraryView.workspace ? 1 : -1;
      _view = view;
    });
  }

  @override
  void didUpdateWidget(WebspaceLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_view == _LibraryView.workspace &&
        !widget.webspaces.any((w) => w.id == widget.selectedWebspaceId)) {
      _view = _LibraryView.webspaces;
      _search.clear();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Webspace? get _selected => widget.webspaces.cast<Webspace?>().firstWhere(
    (w) => w!.id == widget.selectedWebspaceId,
    orElse: () => null,
  );

  List<int> _order(WebspaceId? id) =>
      WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: id,
        webspaces: widget.webspaces,
        siteCount: widget.sites.length,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final groups = _view == _LibraryView.webspaces;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion ? Duration.zero : Motion.libraryNavigation;
    final backButton = SizedBox(
      width: _view == _LibraryView.workspace ? LibraryStyle.target : 0,
      height: LibraryStyle.target,
      child: _view == _LibraryView.workspace
          ? BackButton(onPressed: showWebspaces)
          : null,
    );
    final title = groups
        ? loc.libraryWebspaces
        : _view == _LibraryView.sites
        ? loc.librarySites
        : _selected?.name ?? loc.libraryWebspaces;
    return PopScope(
      canPop: widget.currentSite != null || _view != _LibraryView.workspace,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop &&
            widget.currentSite == null &&
            _view == _LibraryView.workspace) {
          showWebspaces();
        }
      },
      child: Material(
        color: LibraryStyle.background(theme.brightness),
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: LibraryStyle.maxWidth,
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Spacing.lg,
                          Spacing.md,
                          Spacing.sm,
                          Spacing.sm,
                        ),
                        child: Row(
                          children: [
                            backButton,
                            Expanded(
                              child: Text(
                                title,
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
                              tooltip: groups
                                  ? loc.webspacesListCreateButton
                                  : loc.homeAddSite,
                              onPressed: groups
                                  ? widget.onAddWebspace
                                  : widget.onAddSite,
                              icon: const Icon(Icons.add),
                              color: theme.colorScheme.primary,
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
                            hintText: groups
                                ? loc.librarySearchWebspaces
                                : loc.librarySearchSites,
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
                      Expanded(
                        child: ClipRect(
                          child: AnimatedSwitcher(
                            key: ValueKey(reduceMotion),
                            duration: duration,
                            switchInCurve: Motion.libraryCurve,
                            switchOutCurve: Motion.libraryExit,
                            transitionBuilder: _transition,
                            layoutBuilder: (current, previous) => Stack(
                              fit: StackFit.expand,
                              children: [
                                for (final page in previous)
                                  ExcludeSemantics(
                                    child: IgnorePointer(child: page),
                                  ),
                                ?current,
                              ],
                            ),
                            child: Column(
                              key: ValueKey((
                                _view,
                                groups ? null : widget.selectedWebspaceId,
                              )),
                              children: [
                                if (!groups)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      Spacing.lg,
                                      Spacing.lg,
                                      Spacing.lg,
                                      Spacing.xs,
                                    ),
                                    child: Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: Text(
                                        loc.webspacesListSiteCount(
                                          _order(
                                            _view == _LibraryView.sites
                                                ? WebspaceId.all
                                                : widget.selectedWebspaceId,
                                          ).length,
                                        ),
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ),
                                Expanded(
                                  child: groups
                                      ? _groups(context)
                                      : _view == _LibraryView.sites
                                      ? widget.siteTreeBuilder(
                                          context,
                                          _search.text,
                                        )
                                      : _sites(context),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _navigation(context),
          ],
        ),
      ),
    );
  }

  Widget _transition(Widget child, Animation<double> animation) =>
      AnimatedBuilder(
        animation: animation,
        child: child,
        builder: (context, child) {
          final leaving = animation.status == AnimationStatus.reverse;
          if (!_animateNavigation) {
            return leaving ? const SizedBox.shrink() : child!;
          }
          return FadeTransition(
            opacity: animation,
            child: Transform.scale(
              scale:
                  1 +
                  (1 - animation.value) *
                      LibraryStyle.navigationScale *
                      (leaving ? _navigationDirection : -_navigationDirection),
              child: child,
            ),
          );
        },
      );

  Widget _groups(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final shown = widget.webspaces
        .where((w) => w.name.toLowerCase().contains(query))
        .toList();
    if (shown.isEmpty) return _empty(context, groups: true);
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
        final extent = WebspaceGroupTile.extentFor(
          textScaler: scaler,
          textTheme: Theme.of(context).textTheme,
          well: shown
              .map((w) => LibraryStyle.itemWell(w.launcherSize))
              .reduce(math.max),
        );
        return GridView.builder(
          key: const PageStorageKey('webspace-groups'),
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.xl,
            Spacing.lg,
            Spacing.xl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: Spacing.sm,
            mainAxisSpacing: Spacing.xl,
            mainAxisExtent: extent,
          ),
          itemCount: shown.length,
          itemBuilder: (context, index) {
            final webspace = shown[index];
            final position = widget.webspaces.indexOf(webspace);
            return WebspaceGroupTile(
              key: ValueKey(webspace.id),
              webspace: webspace,
              sites: [for (final i in _order(webspace.id)) widget.sites[i]],
              selected: webspace.id == widget.selectedWebspaceId,
              colorIndex: position,
              onOpen: () {
                FocusScope.of(context).unfocus();
                widget.onSelectWebspace(webspace);
              },
              onMenu: () => unawaited(_menu(webspace)),
            );
          },
        );
      },
    );
  }

  Widget _sites(BuildContext context) {
    final order = _order(
      _view == _LibraryView.sites ? WebspaceId.all : widget.selectedWebspaceId,
    );
    final query = _search.text.trim().toLowerCase();
    final shown = order
        .where(
          (i) =>
              widget.sites[i].getDisplayName().toLowerCase().contains(query) ||
              widget.sites[i].initUrl.toLowerCase().contains(query),
        )
        .toList();
    if (shown.isEmpty) return _empty(context, groups: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final columns =
            ((constraints.maxWidth - Spacing.lg * 2 + Spacing.sm) /
                    (LibraryStyle.tileMinWidth * math.max(1, scale * .7) +
                        Spacing.sm))
                .floor()
                .clamp(1, 7);
        return GridView.builder(
          key: PageStorageKey((
            'library-sites',
            _view,
            widget.selectedWebspaceId,
          )),
          padding: const EdgeInsets.all(Spacing.lg),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: Spacing.sm,
            mainAxisSpacing: Spacing.lg,
            mainAxisExtent:
                shown
                    .map(
                      (i) =>
                          LibraryStyle.itemWell(widget.sites[i].launcherSize),
                    )
                    .reduce(math.max) +
                Spacing.xl +
                scale * 58,
          ),
          itemCount: shown.length,
          itemBuilder: (context, index) {
            final site = widget.sites[shown[index]];
            return SiteGridTile(
              key: ValueKey(site.siteId),
              site: site,
              listIndex: order.indexOf(shown[index]),
              selected: identical(site, widget.currentSite),
              showTabCount: widget.showsTabCount(site) && site.tabs.length > 1,
              layout: SiteGridTileLayout.library,
              onOpen: () {
                FocusScope.of(context).unfocus();
                widget.onOpenSite(site);
              },
              onMenu: (context, {required globalPosition}) => widget.onSiteMenu(
                context,
                site: site,
                position: globalPosition,
              ),
              onReorder: query.isEmpty && order.length > 1
                  ? widget.onReorderSite
                  : null,
            );
          },
        );
      },
    );
  }

  Widget _empty(BuildContext context, {required bool groups}) {
    final loc = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Text(
          _search.text.trim().isNotEmpty
              ? loc.libraryNoResults
              : groups
              ? loc.webspacesListEmpty
              : loc.homeNoSitesInWebspace,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Future<void> _menu(Webspace webspace) async {
    final loc = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_GroupAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                webspace.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(loc.commonEdit),
              onTap: () => Navigator.pop(context, _GroupAction.edit),
            ),
            ListTile(
              leading: const Icon(Icons.photo_size_select_large_outlined),
              title: Text(loc.libraryItemSize),
              onTap: () => Navigator.pop(context, _GroupAction.resize),
            ),
            if (!webspace.isAll)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(loc.commonDelete),
                onTap: () => Navigator.pop(context, _GroupAction.delete),
              ),
            if (widget.onReorder != null && !webspace.isAll)
              for (final delta in [-1, 1])
                if (widget.webspaces.indexOf(webspace) + delta > 0 &&
                    widget.webspaces.indexOf(webspace) + delta <
                        widget.webspaces.length)
                  ListTile(
                    leading: Icon(
                      delta < 0 ? Icons.arrow_upward : Icons.arrow_downward,
                    ),
                    title: Text(
                      delta < 0
                          ? WidgetsLocalizations.of(context).reorderItemUp
                          : WidgetsLocalizations.of(context).reorderItemDown,
                    ),
                    onTap: () {
                      final from = widget.webspaces.indexOf(webspace);
                      widget.onReorder!(
                        from,
                        newIndex: delta < 0 ? from - 1 : from + 2,
                      );
                      Navigator.pop(context);
                    },
                  ),
          ],
        ),
      ),
    );
    if (!mounted || !widget.webspaces.contains(webspace)) return;
    switch (action) {
      case _GroupAction.edit:
        widget.onEditWebspace(webspace);
      case _GroupAction.delete:
        widget.onDeleteWebspace(webspace);
      case _GroupAction.resize:
        final size = await showLauncherSizePicker(
          context,
          current: webspace.launcherSize,
        );
        if (size != null && mounted && widget.webspaces.contains(webspace)) {
          widget.onResizeWebspace(webspace, size: size);
        }
      case null:
        return;
    }
  }

  Widget _navigation(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final active = _settingsOpen
        ? 2
        : _view == _LibraryView.sites
        ? 0
        : 1;
    final items = [
      (Icons.account_tree_outlined, loc.librarySites),
      (Icons.apps_rounded, loc.libraryWebspaces),
      (Icons.settings_outlined, loc.homeSettingsMenu),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withAlpha(80),
            width: Chrome.hairlineWidth,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (var index = 0; index < items.length; index++)
              Expanded(
                child: Semantics(
                  selected: active == index,
                  child: InkWell(
                    onTap: () => unawaited(_destination(index)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.xs,
                        vertical: Spacing.md,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            items[index].$1,
                            color: active == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: Spacing.xs),
                          Text(
                            items[index].$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: active == index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _destination(int index) async {
    FocusScope.of(context).unfocus();
    if (index == 0) {
      final all = widget.webspaces.where((w) => w.isAll).firstOrNull;
      if (all != null) widget.onSelectWebspace(all);
      _show(_LibraryView.sites);
    } else if (index == 1) {
      showWebspaces();
    } else if (!_settingsOpen) {
      setState(() => _settingsOpen = true);
      try {
        await widget.onOpenSettings();
      } finally {
        if (mounted) setState(() => _settingsOpen = false);
      }
    }
  }
}
