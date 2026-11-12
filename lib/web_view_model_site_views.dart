import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/web_extension_attach_engine.dart';
import 'package:webspace/services/webview_controller.dart';

/// A tab's live webview kept, paused, while another tab of its site is
/// shown (TAB-023): the widget that holds its platform view and its
/// controller.
typedef WarmView = ({Widget? webview, WebViewController controller});

/// A site's webviews: the one its slot shows and the warm ones it keeps for
/// tabs it does not show (TAB-002, TAB-023). Only these methods move a view
/// between the two, so no view is shown and warm at once.
final class SiteViews {
  /// The shown view's widget, its controller and where the extensions it was
  /// built with open their pages (WEBEXT-008).
  Widget? webview;
  WebViewController? controller;
  ExtensionHome? liveExtensions;

  final Map<TabId, WarmView> _warm = {};

  /// Views let go of while the site's own stays: each may still send until
  /// its page is gone, on the site's route, so the site's leave waits for
  /// them too (PROXY-008).
  final Set<WebViewController> _departing = {};

  /// The warm views by tab (`warm[s]`).
  Map<TabId, WarmView> get warm => Map.unmodifiable(_warm);

  /// The shown view kept as [tab]'s warm one; its controller, or null with
  /// none shown.
  WebViewController? keepShown({required TabId tab, required Commit commit}) {
    final shown = controller;
    if (shown == null) return null;
    _warm[tab] = (webview: webview, controller: shown);
    commit.wrote(ModelVar.warm);
    _clearShown();
    return shown;
  }

  /// [tab]'s warm view shown again; its controller.
  WebViewController show({required TabId tab, required Commit commit}) {
    final view = _warm.remove(tab)!;
    commit.wrote(ModelVar.warm);
    webview = view.webview;
    controller = view.controller;
    return view.controller;
  }

  /// [tab]'s warm view let go of.
  void drop({required TabId tab, required Commit commit}) {
    final view = _warm.remove(tab);
    if (view == null) return;
    commit.wrote(ModelVar.warm);
    _depart(view.controller);
  }

  /// The shown view let go of while the warm ones stay; false, with nothing
  /// done, when none is warm.
  bool dropShown() {
    if (_warm.isEmpty) return false;
    final gone = controller;
    _clearShown();
    if (gone != null) _depart(gone);
    return true;
  }

  /// Every view let go of, in [commit]: what may still send until its page
  /// is gone, [shown] for the shown one, which a dead renderer leaves out.
  LeavingView? letGoOfAll({required LeavingView? shown, required Commit commit}) {
    final leaving = [
      ?shown,
      for (final w in _warm.values) w.controller,
      ..._departing,
    ];
    if (_warm.isNotEmpty) {
      _warm.clear();
      commit.wrote(ModelVar.warm);
    }
    _departing.clear();
    _clearShown();
    return switch (leaving) {
      [] => null,
      [final only] => only,
      _ => LeavingViews(leaving),
    };
  }

  void _clearShown() {
    webview = null;
    controller = null;
    liveExtensions = null;
  }

  void _depart(WebViewController gone) {
    _departing.add(gone);
    unawaited(gone.destroyed().then((_) => _departing.remove(gone)));
  }
}
