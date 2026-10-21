import 'dart:async';

import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/settings/launcher_item_size.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_activation_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// What the webspace flows ask the user.
abstract interface class WebspacePrompts {
  /// Opens the webspace editor on [webspace]; [onSave] runs with the edited
  /// copy before the editor closes.
  Future<void> edit(
    Webspace webspace, {
    required List<WebViewModel> sites,
    required bool readOnly,
    required void Function(Webspace saved) onSave,
  });

  Future<bool> confirmDelete(Webspace webspace);
}

/// What the webspace flows ask of the page.
abstract interface class WebspacesHost implements PageHost {
  void openDrawer();
}

/// Named webspaces (spec `webspaces`): adding, editing, deleting, selecting
/// and ordering them, and the order of the sites inside the one selected.
class WebspacesController {
  WebspacesController(
    this._sites, {
    required WebspacesHost host,
    required WebspacePrompts prompts,
    required ShellStore shell,
    required SiteActivationController activation,
  }) : _host = host,
       _prompts = prompts,
       _shell = shell,
       _activation = activation;

  final SiteRuntime _sites;
  final WebspacesHost _host;
  final WebspacePrompts _prompts;
  final ShellStore _shell;
  final SiteActivationController _activation;

  /// Set while a webspace switch unloads sites; opening a site waits on it
  /// so the unload finishes before anything new loads.
  Completer<void>? _switchCompleter;

  Future<void>? get switchInFlight => _switchCompleter?.future;

  /// WEBSPACE-012 helper: switch the active webspace to "All" if [model]
  /// isn't a member of the current named webspace, with a snackbar.
  Future<void> revealSite(WebViewModel model) async {
    final index = _sites.models.indexOf(model);
    if (index < 0 ||
        _sites.selectedWebspaceId == null ||
        _sites.selectedWebspaceId == WebspaceId.all) {
      return;
    }
    final ws = _sites.webspaces.firstWhere(
      (w) => w.id == _sites.selectedWebspaceId,
      orElse: () => _sites.webspaces.first,
    );
    if (ws.siteIndices.contains(index)) return;
    _sites.selectedWebspaceId = WebspaceId.all;
    _host.rebuild();
    await _shell.saveSelectedWebspaceId();
    _host.toast((loc) => loc.homeSwitchedToAllToOpen(model.getDisplayName()));
  }

  Future<void> add() async {
    final webspace = Webspace(name: '');
    await _prompts.edit(
      webspace,
      sites: _sites.models,
      readOnly: false,
      onSave: (updatedWebspace) {
        // The editor returns positional siteIndices; translate to
        // siteIds (the persisted source of truth) before storing.
        final selectedSiteIds = <SiteId>[
          for (final i in updatedWebspace.siteIndices)
            if (i >= 0 && i < _sites.models.length) _sites.models[i].siteId,
        ];
        _sites.webspaces.add(
          updatedWebspace.copyWith(siteIds: selectedSiteIds),
        );
        _sites.resolveWebspaceIndices();
        _host.rebuild();
        unawaited(_shell.saveWebspaces());
      },
    );
  }

  Future<void> edit(Webspace webspace) async {
    // For "All" webspace, show all sites as selected but read-only.
    // The synthetic projection has to populate BOTH siteIds and
    // siteIndices so the editor's "selected" state matches.
    final webspaceToEdit = webspace.id == WebspaceId.all
        ? Webspace(
            id: WebspaceId.all,
            name: 'All',
            siteIds: [for (final m in _sites.models) m.siteId],
            siteIndices: List<int>.generate(
              _sites.models.length,
              (index) => index,
            ),
          )
        : webspace;

    await _prompts.edit(
      webspaceToEdit,
      sites: _sites.models,
      readOnly: webspace.id == WebspaceId.all,
      onSave: (updatedWebspace) {
        if (updatedWebspace.id == WebspaceId.all) return;

        // Translate the editor's index-based selection back into
        // the siteId-keyed persisted membership.
        final selectedSiteIds = <SiteId>[
          for (final i in updatedWebspace.siteIndices)
            if (i >= 0 && i < _sites.models.length) _sites.models[i].siteId,
        ];
        final index = _sites.webspaces.indexWhere(
          (ws) => ws.id == updatedWebspace.id,
        );
        if (index != -1) {
          _sites.webspaces[index] = updatedWebspace.copyWith(
            siteIds: selectedSiteIds,
          );
          _sites.resolveWebspaceIndices();
        }
        _host.rebuild();
        unawaited(_shell.saveWebspaces());
      },
    );
  }

  Future<void> delete(Webspace webspace) async {
    if (webspace.id == WebspaceId.all) {
      _host.toast((loc) => loc.homeCannotDeleteAllWebspace);
      return;
    }

    final confirmed = await _prompts.confirmDelete(webspace);

    if (confirmed != true || !_host.mounted) return;

    final wasSelected = _sites.selectedWebspaceId == webspace.id;
    _sites.webspaces.removeWhere((ws) => ws.id == webspace.id);
    if (wasSelected) {
      _sites.selectedWebspaceId = WebspaceId.all;
    }
    _host.rebuild();
    if (wasSelected) {
      await _activation.activate(null);
      if (!_host.mounted) return;
    }
    await _shell.saveWebspaces();
    await _shell.saveSelectedWebspaceId();
    await _shell.saveCurrentIndex();
  }

  Future<void> select(Webspace webspace) async {
    if (_sites.selectedWebspaceId == webspace.id) {
      _host.openDrawer();
      return;
    }

    // Signal that a webspace switch is in progress. Site selection (onTap)
    // awaits this so the unload finishes before any new site is loaded.
    final completer = Completer<void>();
    _switchCompleter = completer;

    try {
      Set<WebViewModel> shown() =>
          {for (final i in _sites.filteredIndices()) _sites.models[i]};
      final previous = shown();

      _sites.selectedWebspaceId = webspace.id;
      _host.rebuild();

      // Open drawer immediately so the user sees instant feedback on tap
      _host.openDrawer();

      // A newer input supersedes the switch's unloads, as it would an
      // activation's (WEBSPACE-013).
      await _activation.switchWebspace(
        leaving: previous.difference(shown()),
      );
      if (!_host.mounted) return;

      _host.rebuild();
      await _shell.saveSelectedWebspaceId();
      await _shell.saveCurrentIndex();
    } finally {
      completer.complete();
      if (_switchCompleter == completer) {
        _switchCompleter = null;
      }
    }
  }

  void reorder(int oldIndex, {required int newIndex}) {
    final moved = WebspaceSelectionEngine.reorder(
      _sites.webspaces,
      from: oldIndex,
      to: newIndex,
    );
    if (!moved) return;
    _host.rebuild();
    unawaited(_shell.saveWebspaces());
  }

  Future<void> resize(
    Webspace webspace, {
    required LauncherItemSize size,
  }) async {
    if (!_sites.webspaces.contains(webspace)) return;
    webspace.launcherSize = size;
    _host.rebuild();
    await _shell.saveWebspaces();
  }

  /// Whether the currently-selected view supports drag/menu reordering.
  /// Both a named webspace (reorders its `siteIds`) and the synthetic "All"
  /// view (reorders `_sites.models` globally) qualify; the null/home state
  /// does not.
  bool get canReorderView => _sites.selectedWebspaceId != null;

  /// Reorder the site shown at [oldListIndex] to [newListIndex] within the
  /// current view. Dispatches to the per-webspace `siteIds` reorder for a
  /// named webspace, or the global `_sites.models` reorder for "All".
  /// [oldListIndex]/[newListIndex] are positions in `_sites.filteredIndices()`.
  void reorderSite(int oldListIndex, {required int newListIndex}) {
    final filtered = _sites.filteredIndices();
    if (oldListIndex < 0 || oldListIndex >= filtered.length) return;
    if (newListIndex < 0 || newListIndex >= filtered.length) return;
    if (oldListIndex == newListIndex) return;
    if (_sites.selectedWebspaceId == WebspaceId.all) {
      unawaited(
        _reorderAllSites(
          filtered[oldListIndex],
          newModelIndex: filtered[newListIndex],
        ),
      );
    } else {
      _reorderSiteInWebspace(oldListIndex, newListIndex: newListIndex);
    }
  }

  void _reorderSiteInWebspace(int oldListIndex, {required int newListIndex}) {
    final webspace = _sites.webspaces.cast<Webspace?>().firstWhere(
      (ws) => ws!.id == _sites.selectedWebspaceId,
      orElse: () => null,
    );
    if (webspace == null) return;
    if (oldListIndex < 0 || oldListIndex >= webspace.siteIds.length) return;
    if (newListIndex < 0 || newListIndex >= webspace.siteIds.length) return;
    final movedSiteId = webspace.siteIds.removeAt(oldListIndex);
    webspace.siteIds.insert(newListIndex, movedSiteId);
    _sites.resolveWebspaceIndices();
    _host.rebuild();
    unawaited(_shell.saveWebspaces());
  }

  /// Moves the site at [oldModelIndex] to [newModelIndex] in the "All"
  /// order. Each webview in the stack is keyed by its site, so it keeps its
  /// State.
  Future<void> _reorderAllSites(
    int oldModelIndex, {
    required int newModelIndex,
  }) async {
    if (oldModelIndex < 0 || oldModelIndex >= _sites.models.length) return;
    if (newModelIndex < 0 || newModelIndex >= _sites.models.length) return;
    if (oldModelIndex == newModelIndex) return;
    await _host.commitSites(SitesMoved(oldModelIndex, to: newModelIndex));
    await _shell.saveCurrentIndex();
  }
}
