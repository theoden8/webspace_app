import 'dart:async';

import 'package:webspace/controllers/back_gesture_controller.dart';
import 'package:webspace/controllers/site_reset_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/web_view_model.dart';

/// What the page answers for a keyboard shortcut beyond the controllers that
/// own tabs, reloads and back.
abstract interface class KeyboardShortcutHost {
  bool get mounted;
  bool get kioskLocked;

  /// Whether the page is the route on top ([ShortcutScreen.onTop]).
  bool get onTop;

  /// Puts the cursor in the URL bar with the address selected; false where
  /// no URL bar is on screen.
  bool focusUrlBar();

  /// The site menu's Find in page; false where the find bar cannot show.
  bool findInPage();

  /// What a tap on [site] in the tab strip does.
  Future<void> openSite(WebViewModel site);
}

/// The page's answers to the desktop keyboard shortcuts (NAV-014), each the
/// one its menu, its tab strip or its Tabs sheet gives.
class KeyboardShortcutController implements ShortcutScreen {
  KeyboardShortcutController(
    this._sites, {
    required KeyboardShortcutHost host,
    required TabsController tabs,
    required SiteResetController resets,
    required BackGestureController back,
  }) : _host = host,
       _tabs = tabs,
       _resets = resets,
       _back = back;

  final SiteRuntime _sites;
  final KeyboardShortcutHost _host;
  final TabsController _tabs;
  final SiteResetController _resets;
  final BackGestureController _back;

  late final _keys = KeyboardShortcuts(this);

  void start() => _keys.start();

  void dispose() => _keys.dispose();

  @override
  bool get onTop => _host.mounted && _host.onTop;

  /// Runs [shortcut] for the site on screen, and says whether it did.
  @override
  bool answerShortcut(KeyboardShortcut shortcut) {
    final site = _sites.shown;
    if (site == null) return false;
    if (_host.kioskLocked && !shortcut.keptInKiosk) return false;
    return switch (shortcut) {
      OpenNewTab() => _run(_tabs.forShownSite(_tabs.newTab)),
      CloseActiveTab() => _run(
        _tabs.forShownSite(
          (shown) => _tabs.closeTab(shown, tabId: shown.activeTabId),
        ),
      ),
      FocusUrlBar() => _host.focusUrlBar(),
      ReloadPage() => _run(() => unawaited(_resets.refreshShown())),
      FindInPage() => _host.findInPage(),
      GoBack() => _run(() => unawaited(_back.goBackIfPossible())),
      GoForward() => _run(() => unawaited(_back.goForwardIfPossible())),
      NextSite() => _step(site, by: 1),
      PreviousSite() => _step(site, by: -1),
      SiteAt(:final place) => _openAt(place),
      LastSite() => _openAt(_strip.length - 1),
    };
  }

  static bool _run(void Function()? act) {
    if (act == null) return false;
    act();
    return true;
  }

  List<WebViewModel> get _strip => [
    for (final i in _sites.filteredIndices()) _sites.models[i],
  ];

  bool _step(WebViewModel site, {required int by}) {
    final strip = _strip;
    if (strip.isEmpty) return false;
    final at = strip.indexOf(site);
    final to = at < 0 ? (by > 0 ? 0 : strip.length - 1) : at + by;
    return _openAt(to % strip.length);
  }

  bool _openAt(int place) {
    final strip = _strip;
    if (place < 0 || place >= strip.length) return false;
    final site = strip[place];
    if (!identical(site, _sites.shown)) unawaited(_host.openSite(site));
    return true;
  }
}
