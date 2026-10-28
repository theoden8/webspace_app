import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/background_wake_engine.dart'
    show unreadCountFromTitle;
import 'package:webspace/services/desktop_window.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/menu_bar_tray.dart';
import 'package:webspace/services/status_notifier_tray.dart';
import 'package:webspace/services/tray_icon.dart';
import 'package:webspace/services/tray_menu_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/utils/concurrency.dart';
import 'package:webspace/widgets/root_messenger.dart';

/// The icon a desktop keeps for the app in its status area while a close only
/// hides the window (NOTIF-019): it shows the window, opens a site with
/// notifications on as a tap on its notification does, and quits. It is
/// there exactly while [AppPref.keepRunningWhenClosed] is on, on a desktop
/// whose runner can hide its window ([DesktopWindow.offered]), and, where
/// the tray is still [experimental] (macOS), while its experiment is
/// reachable.
class DesktopTray {
  DesktopTray(this._sites, {required void Function(SiteId site) open})
      : _open = open;

  /// The status area a test stands in for.
  @visibleForTesting
  static TrayIcon Function(TrayHandlers handlers)? debugIconOverride;

  final SiteRuntime _sites;
  final void Function(SiteId site) _open;
  final _menus = TrayMenus();

  /// Shows and removals, one at a time, so a removal is never overtaken by a
  /// show that started before it.
  final _turns = SerialQueue('tray');

  late final TrayIcon _icon = (debugIconOverride ?? _platformIcon)(
      (pressed: _pressed, opening: refresh));
  var _shown = false;

  static TrayIcon _platformIcon(TrayHandlers handlers) => hostIsMacOS
      ? MenuBarTray(handlers: handlers)
      : StatusNotifierTray(handlers: handlers);

  /// Whether this host shows the tray only with the Tray icon experiment on
  /// (DEVTOOLS-011): macOS. On Linux it graduated.
  static bool get experimental => debugExperimental ?? hostIsMacOS;

  /// Lets a test run either rule whatever its host.
  @visibleForTesting
  static bool? debugExperimental;

  /// Whether a close that only hides the window leaves an icon behind.
  static bool get offered =>
      !experimental ||
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.desktopTray);

  static bool get _wanted =>
      DesktopWindow.offered && AppPref.keepRunningWhenClosed.value && offered;

  void start() {
    if (!DesktopWindow.offered) return;
    AppPref.anyChange.addListener(_follow);
    _follow();
  }

  void dispose() {
    AppPref.anyChange.removeListener(_follow);
    if (_shown) _turns.enqueue(_remove);
  }

  /// The last answer of [_wanted] acted on, so the queue gets each flip once
  /// and in order, whatever is still in it.
  var _decided = false;

  void _follow() {
    final wanted = _wanted;
    if (wanted == _decided) return;
    _decided = wanted;
    if (wanted) {
      unawaited(refresh());
    } else {
      _turns.enqueue(_remove);
    }
  }

  Future<void> _remove() async {
    _shown = false;
    await _icon.remove();
  }

  /// Puts the menu as it stands now in the tray: each site with
  /// notifications on, with the unread count its page's title shows.
  Future<void> refresh() async {
    final labels = _labels();
    if (labels == null || !_wanted) return;
    final notifying = [
      for (final m in _sites.models)
        if (m.effectiveNotificationsEnabled) m,
    ];
    final titles = await Future.wait([
      for (final m in notifying) m.controller?.getTitle() ?? Future.value(),
    ]);
    final menu = _menus.build(labels: labels, sites: [
      for (final (i, m) in notifying.indexed)
        (id: m.siteId, name: m.name, unread: unreadCountFromTitle(titles[i])),
    ]);
    // Queued rather than waited on: the status area's own calls land here,
    // and on Linux one can arrive inside the turn that opened its connection.
    final shown = Completer<void>();
    _turns.enqueue(() async {
      try {
        // Turned off while the titles were read.
        if (!_wanted) return;
        _shown = true;
        await _icon.show(menu);
      } finally {
        shown.complete();
      }
    });
    await shown.future;
  }

  /// The tray's words in the language the app shows, from the root
  /// messenger, which outlives every page.
  static TrayLabels? _labels() {
    final context = rootScaffoldMessengerKey.currentContext;
    if (context == null) return null;
    final loc = AppLocalizations.of(context);
    return (title: loc.appTitle, show: loc.trayShowApp, quit: loc.trayQuitApp);
  }

  void _pressed(TrayAction action) {
    switch (action) {
      case TrayShow():
        unawaited(DesktopWindow.instance.show());
      case TrayOpenSite(:final site):
        _open(site);
      case TrayQuit():
        unawaited(DesktopWindow.instance.quit());
    }
  }
}
