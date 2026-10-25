// Alternative design driven by a TV remote's D-pad and OK key alone (NAV-016),
// with Android's key bindings (flutter_test's default platform) and the
// app's remote chrome around it, as app.dart builds it on a TV.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/services/remote_input.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/library_layout.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/remote_controls.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_list_menu.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';

final Uint8List _icon = image.encodePng(image.Image(width: 2, height: 2));

class _LibraryHarness extends StatefulWidget {
  const _LibraryHarness();
  @override
  State<_LibraryHarness> createState() => _LibraryHarnessState();
}

class _LibraryHarnessState extends State<_LibraryHarness> {
  final library = GlobalKey<WebspaceLibraryState>();
  final sites = [
    for (var i = 0; i < 8; i++)
      WebViewModel(
        name: i == 0 ? 'GitHub' : 'Site $i',
        initUrl: 'https://site$i.example.test',
        customIconPng: _icon,
        captures: CaptureGrants(
          camera: (mode: CameraAccessMode.real, source: null),
          microphone: (mode: MicrophoneAccessMode.ask, source: null),
          screenShare: (mode: ScreenShareMode.ask, source: null),
        ),
      ),
  ];
  late final webspaces = [
    Webspace.all(),
    Webspace(name: 'Work', siteIds: [sites[0].siteId, sites[1].siteId]),
    Webspace(name: 'Privacy', siteIds: [sites[2].siteId]),
    Webspace(
      name: 'An unusually long collection name that must remain usable',
      siteIds: [],
    ),
  ];
  WebspaceId selected = WebspaceId.all;
  Webspace? edited;
  Webspace? deleted;
  WebViewModel? opened;
  var opens = 0;
  SiteListAction? siteAction;
  var settingsOpened = 0;
  final tabsScopes = <WebspaceId>[];
  final siteMoves = <(int, int)>[];
  final addedInto = <WebspaceId?>[];
  var webspacesAdded = 0;
  WebViewModel? menuFor;

  void disableTabs(WebViewModel site) =>
      setState(() => site.tabsEnabled = false);

  @override
  Widget build(BuildContext context) {
    WebspaceSelectionEngine.resolveIndices(
      webspaces,
      siteIdsByPosition: [for (final site in sites) site.siteId],
    );
    // The page's Back, which closes an open folder first.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) library.currentState!.closeFolder();
      },
      child: Scaffold(
        body: WebspaceLibrary(
          key: library,
          webspaces: webspaces,
          sites: sites,
          selectedWebspaceId: selected,
          currentSite: null,
          showsTabCount: (site) => site.effectiveTabsEnabled,
          onSelectWebspace: (webspace) {
            setState(() => selected = webspace.id);
            library.currentState!.openFolder();
          },
          onAddWebspace: () => webspacesAdded++,
          onEditWebspace: (webspace) => edited = webspace,
          onDeleteWebspace: (webspace) => deleted = webspace,
          onReorder: (from, {required newIndex}) => setState(() {
            WebspaceSelectionEngine.reorder(
              webspaces,
              from: from,
              to: newIndex,
            );
          }),
          onOpenSite: (site) {
            opened = site;
            opens++;
          },
          onSiteMenu: (context, {required site, required position}) async {
            menuFor = site;
            siteAction = await showSiteListMenu(
              context,
              position: position,
              canMoveUp: false,
              canMoveDown: false,
              archived: false,
            );
          },
          onReorderSite: (from, {required to}) => siteMoves.add((from, to)),
          onAddSite: ({required into}) => addedInto.add(into),
          onShowTabs: tabsScopes.add,
          onOpenSettings: () async => settingsOpened++,
          accentColor: AccentColor.blue,
        ),
      ),
    );
  }
}


final _panel = find.byKey(const ValueKey('library-folder'));

/// The launcher tile that has focus, and the first text it shows.
(Type?, String?) _focused() {
  final context = FocusManager.instance.primaryFocus?.context;
  Widget? tile;
  context?.visitAncestorElements((e) {
    if (e.widget is SiteGridTile || e.widget is WebspaceGroupTile) {
      tile = e.widget;
      return false;
    }
    return true;
  });
  return switch (tile) {
    final SiteGridTile t => (SiteGridTile, t.site.name),
    final WebspaceGroupTile t => (WebspaceGroupTile, t.webspace.name),
    _ => (null, null),
  };
}

bool _focusInPanel(WidgetTester tester) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final panel = tester.element(_panel);
  var inside = false;
  context.visitAncestorElements((e) {
    inside = identical(e, panel);
    return !inside;
  });
  return inside;
}

Future<void> _press(
  WidgetTester tester, {
  required List<LogicalKeyboardKey> keys,
}) async {
  for (final key in keys) {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }
}

/// OK held past the key's repeat delay, then let go.
Future<void> _hold(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
  await tester.pump();
  await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

const _down = LogicalKeyboardKey.arrowDown;
const _left = LogicalKeyboardKey.arrowLeft;
const _right = LogicalKeyboardKey.arrowRight;
const _ok = LogicalKeyboardKey.select;

Future<_LibraryHarnessState> _pumpTv(WidgetTester tester) async {
  RemoteInput.debugDrivenOverride = true;
  addTearDown(() => RemoteInput.debugDrivenOverride = null);
  // A 1080p TV: 960 x 540 at density 2.
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => RemoteControls(child: child!),
    home: const _LibraryHarness(),
  ));
  await tester.pumpAndSettle();
  return tester.state<_LibraryHarnessState>(find.byType(_LibraryHarness));
}

/// From the top of the home screen into the Work folder, and onto its last
/// site: the add button, the search field, the folders, then the folder's
/// header and its sites.
Future<void> _toWorksSite(WidgetTester tester) async {
  await _press(tester, keys: [_down, _down, _down]);
  expect(_focused().$1, WebspaceGroupTile,
      reason: 'Down leaves the search field for the folders');
  await _press(tester, keys: [_left, _left, _left, _right]);
  expect(_focused(), (WebspaceGroupTile, 'Work'));
  await _press(tester, keys: [_ok]);
  expect(_panel, findsOneWidget);
  await _press(tester, keys: [_down, _down]);
  expect(_focusInPanel(tester), isTrue,
      reason: 'the dimmed home behind an open folder takes no focus');
  expect(_focused(), (SiteGridTile, 'Site 1'));
}

void main() {
  // A remote moves through the grids here, as their arrows lay them out.
  setUp(() {
    for (final pref in [AppPref.libraryLayout, AppPref.libraryWebspaceLayout]) {
      pref.debugValue = LibraryLayout.grid.name;
      addTearDown(() => pref.debugValue = pref.fallback);
    }
  });

  testWidgets(
      'a remote reaches a folder and opens a site in Alternative design '
      '(NAV-016)', (tester) async {
    final state = await _pumpTv(tester);
    await _toWorksSite(tester);

    await _press(tester, keys: [_ok]);

    expect(state.opened?.name, 'Site 1');
    expect(state.opens, 1);
  });

  testWidgets(
      'holding OK on a site opens its menu with the moves a drag makes '
      '(NAV-016)', (tester) async {
    final state = await _pumpTv(tester);
    await _toWorksSite(tester);

    await _hold(tester);

    expect(state.opens, 0, reason: 'a held OK never opens the site');
    expect(state.menuFor?.name, 'Site 1');
    expect(find.text('Move Up'), findsOneWidget);
    expect(find.text('Move Down'), findsNothing,
        reason: 'Site 1 is the last in Work');

    await tester.tap(find.text('Move Up'));
    await tester.pumpAndSettle();

    expect(state.siteMoves, [(1, 0)]);
    expect(state.siteAction, isNull, reason: 'the grid made the move itself');
  });

  testWidgets('holding OK on a folder offers its moves; All never moves',
      (tester) async {
    final state = await _pumpTv(tester);
    await _press(tester, keys: [_down, _down, _down, _left]);
    expect(_focused(), (WebspaceGroupTile, 'Privacy'));

    await _hold(tester);
    expect(find.text('Move Up'), findsOneWidget);
    expect(find.text('Move Down'), findsOneWidget);
    await tester.tap(find.text('Move Up'));
    await tester.pumpAndSettle();
    expect(state.webspaces.map((w) => w.name).take(3),
        ['All', 'Privacy', 'Work']);

    await _press(tester, keys: [_left]);
    expect(_focused(), (WebspaceGroupTile, 'All'));
    await _hold(tester);
    expect(find.text('Move Up'), findsNothing);
    expect(find.text('Move Down'), findsNothing);
  });

  testWidgets('without a remote a held key opens the menu, with no moves',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _LibraryHarness(),
    ));
    await tester.pumpAndSettle();
    final state =
        tester.state<_LibraryHarnessState>(find.byType(_LibraryHarness));
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.descendant(
      of: _panel,
      matching: find.text('Site 1'),
    ))).requestFocus();
    await tester.pump();

    await _hold(tester);

    expect(state.menuFor?.name, 'Site 1');
    expect(state.opens, 0);
    expect(find.text('Move Up'), findsNothing,
        reason: 'a drag moves an icon wherever a finger or pointer can');
  });
}
