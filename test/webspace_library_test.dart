import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';
import 'helpers/localized.dart';
import 'helpers/group_tile.dart';

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
  var settingsOpened = 0;
  final tabsScopes = <WebspaceId>[];
  final siteMoves = <(int, int)>[];
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
          onAddWebspace: () {},
          onEditWebspace: (webspace) => edited = webspace,
          onDeleteWebspace: (webspace) => deleted = webspace,
          onReorder: (from, {required newIndex}) => setState(() {
            WebspaceSelectionEngine.reorder(
              webspaces,
              from: from,
              to: newIndex,
            );
          }),
          onOpenSite: (site) => opened = site,
          onSiteMenu: (context, {required site, required position}) =>
              menuFor = site,
          onReorderSite: (from, {required to}) => siteMoves.add((from, to)),
          onAddSite: () {},
          onShowTabs: tabsScopes.add,
          onOpenSettings: () async => settingsOpened++,
        ),
      ),
    );
  }
}

Finder _group(String name) => find.descendant(
  of: find.byType(WebspaceGroupTile),
  matching: find.text(name),
);

final _panel = find.byKey(const ValueKey('library-folder'));

Finder _inPanel(Finder finder) => find.descendant(of: _panel, matching: finder);

/// A tap beside the open folder's panel, as a phone closes a folder.
Future<void> _tapOutside(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

/// The well a folder tile draws its previews in.
Rect _well(WidgetTester tester, {required String name}) => tester.getRect(
  find.descendant(
    of: find.ancestor(
      of: _group(name),
      matching: find.byType(WebspaceGroupTile),
    ),
    matching: find.byType(AnimatedContainer),
  ),
);

/// A long press on [from] that lets go over [to], or where it began.
Future<void> _lift(
  WidgetTester tester, {
  required Finder from,
  Finder? to,
}) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(const Duration(milliseconds: 600));
  if (to != null) {
    await gesture.moveTo(tester.getCenter(to));
    await tester.pump();
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'selection keeps group backgrounds stable in ${brightness.name}',
      (tester) async {
        await pumpLocalized(
          tester,
          home: const _LibraryHarness(),
          theme: ThemeData(
            colorScheme: buildAccentColorScheme(
              accentBlue,
              brightness: brightness,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final state = tester.state<_LibraryHarnessState>(
          find.byType(_LibraryHarness),
        );
        final colors = {
          for (final group in state.webspaces)
            group.id: groupBackground(tester, id: group.id),
        };
        for (final name in ['Work', 'Privacy', 'All']) {
          await tester.tap(_group(name));
          await tester.pumpAndSettle();
          await _tapOutside(tester);
          for (final entry in colors.entries) {
            expect(groupBackground(tester, id: entry.key), entry.value);
          }
          final selected = find.byKey(ValueKey(state.selected));
          final well = tester.widget<AnimatedContainer>(
            find.descendant(
              of: selected,
              matching: find.byType(AnimatedContainer),
            ),
          );
          final outline =
              (well.foregroundDecoration! as BoxDecoration).border! as Border;
          expect(
            outline.top.color,
            Theme.of(tester.element(selected)).colorScheme.primary,
          );
          expect(outline.top.width, greaterThan(0));
          expect(
            find.descendant(
              of: selected,
              matching: find.byIcon(Icons.check_circle),
            ),
            findsOneWidget,
          );
        }
      },
    );
  }

  testWidgets(
    'a tap beside the panel, Back and Escape each close a folder, keeping search and selection (WEBSPACE-008)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      final membership = [...state.webspaces[1].siteIds];
      await tester.enterText(find.byType(TextField), 'w');
      await tester.pumpAndSettle();
      final closers = <String, Future<void> Function()>{
        'tap beside': () => _tapOutside(tester),
        'Back': () async {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        },
        'Escape': () async {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        },
      };
      for (final MapEntry(key: how, value: close) in closers.entries) {
        await tester.tap(_group('Work'));
        await tester.pumpAndSettle();
        expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(2));
        expect(
          _group('Work').hitTestable(),
          findsNothing,
          reason: 'the grid under an open folder takes no input',
        );
        await close();
        expect(_panel, findsNothing, reason: how);
        expect(_group('Work').hitTestable(), findsOneWidget, reason: how);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'w',
          reason: how,
        );
      }
      expect(state.selected, state.webspaces[1].id);
      expect(state.webspaces[1].siteIds, membership);
      expect(state.opened, isNull);
    },
  );

  testWidgets('an empty group opens and closes', (tester) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    final state = tester.state<_LibraryHarnessState>(
      find.byType(_LibraryHarness),
    );
    await tester.tap(_group(state.webspaces.last.name));
    await tester.pumpAndSettle();
    expect(_inPanel(find.text('No sites in this webspace')), findsOneWidget);
    expect(find.byType(SiteGridTile), findsNothing);
    await _tapOutside(tester);
    expect(_panel, findsNothing);
    expect(_group('Work').hitTestable(), findsOneWidget);
  });

  testWidgets('scrolling, stray drags and taps inside a folder keep it open', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      home: const _LibraryHarness(),
      size: const Size(411, 600),
    );
    await tester.pumpAndSettle();
    await tester.tap(_group('All'));
    await tester.pumpAndSettle();
    final grid = _inPanel(find.byType(CustomScrollView));
    await tester.drag(grid, const Offset(0, -150));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: grid, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, greaterThan(0));
    await tester.flingFrom(tester.getCenter(grid), const Offset(150, 0), 1000);
    await tester.pumpAndSettle();
    await tester.tap(_inPanel(find.text('8 sites')));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    expect(
      tester.state<_LibraryHarnessState>(find.byType(_LibraryHarness)).opened,
      isNull,
    );
  });

  testWidgets(
    'a folder grows out of its tile over the grid and shrinks back into it (WEBSPACE-008)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final well = _well(tester, name: 'Work');
      await tester.tap(_group('Work'));
      await tester.pump();
      expect(tester.getRect(_panel), well, reason: 'it starts as the tile');
      await tester.pump(const Duration(milliseconds: 60));
      final growing = tester.getRect(_panel);
      expect(_group('Work'), findsOneWidget, reason: 'the grid stays drawn');
      await tester.pumpAndSettle();
      final open = tester.getRect(_panel);
      expect(growing.width, greaterThan(well.width));
      expect(growing.width, lessThan(open.width));
      expect(open.width, greaterThan(well.width * 3));
      await _tapOutside(tester);
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final shrinking = tester.getRect(_panel);
      expect(shrinking.width, lessThan(open.width));
      expect(shrinking.width, greaterThan(well.width));
      expect(
        (shrinking.center - well.center).distance,
        lessThan((open.center - well.center).distance),
        reason: 'closing heads back into the tile',
      );
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
    },
  );

  testWidgets(
    'opening a folder keeps the chrome still and accepts Back mid-animation',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final search = tester.getRect(find.byType(TextField));
      final settings = tester.getRect(find.byTooltip('App Settings'));
      await tester.tap(_group('Work'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(WebspaceGroupTile).hitTestable(), findsNothing);
      expect(tester.getRect(find.byType(TextField)), search);
      expect(tester.getRect(find.byTooltip('App Settings')), settings);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_group('Work').hitTestable(), findsOneWidget);
      expect(find.byType(SiteGridTile), findsNothing);
      expect(tester.getRect(find.byType(TextField)), search);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'App Settings opens from the home header, with no bottom bar (WEBSPACE-002)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      expect(find.text('Sites'), findsNothing);
      await tester.tap(find.byTooltip('App Settings'));
      await tester.pump();
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      expect(find.text('Sites'), findsNothing);
      expect(find.byTooltip('App Settings').hitTestable(), findsNothing);
      await _tapOutside(tester);
      await tester.tap(find.byTooltip('App Settings'));
      await tester.pump();
      expect(state.settingsOpened, 2);
    },
  );

  testWidgets(
    'the tab tree button counts and opens the tabs of the home or the open folder (WEBSPACE-004)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      final home = find.byTooltip('Tabs');
      expect(
        find.descendant(of: home, matching: find.text('8')),
        findsOneWidget,
      );
      expect(
        tester.getRect(home).left,
        greaterThan(tester.getRect(find.byTooltip('Create Webspace')).right),
      );
      expect(
        tester.getRect(home).right,
        closeTo(tester.getRect(find.byTooltip('App Settings')).left, Spacing.sm),
        reason: 'the tab button sits beside App Settings',
      );
      state.disableTabs(state.sites[1]);
      await tester.pump();
      expect(
        find.descendant(of: home, matching: find.text('7')),
        findsOneWidget,
        reason: 'a site without tabs adds none to the count',
      );
      await tester.tap(home);
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      final folder = _inPanel(find.byTooltip('Tabs'));
      expect(
        find.descendant(of: folder, matching: find.text('1')),
        findsOneWidget,
      );
      await tester.tap(folder);
      expect(state.tabsScopes, [WebspaceId.all, state.webspaces[1].id]);
      await _tapOutside(tester);
      await tester.tap(_group(state.webspaces.last.name));
      await tester.pumpAndSettle();
      expect(
        _inPanel(find.byTooltip('Tabs')),
        findsNothing,
        reason: 'a webspace without tabs has no tree',
      );
    },
  );

  testWidgets('reduced motion opens and closes a folder at once', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      home: const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: _LibraryHarness(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_group('Work'));
    await tester.pump();
    final open = tester.getRect(_panel);
    expect(find.byType(SiteGridTile).hitTestable(), findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(_panel), open);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(_panel, findsNothing);
    expect(_group('Work').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'folders preview the live members and count the hidden sites (WEBSPACE-003)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      expect(find.text('+5'), findsOneWidget);
      final all = find.byWidgetPredicate(
        (widget) => widget is WebspaceGroupTile && widget.webspace.isAll,
      );
      expect(
        find.descendant(of: all, matching: find.byIcon(Icons.check_circle)),
        findsOneWidget,
      );
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      final work = find.byKey(ValueKey(state.webspaces[1].id));
      final icons = tester.widgetList<UnifiedFaviconImage>(
        find.descendant(of: work, matching: find.byType(UnifiedFaviconImage)),
      );
      expect(icons.map((icon) => icon.url), [
        'https://site0.example.test',
        'https://site1.example.test',
      ]);
      expect(find.byType(SiteGridTile), findsNothing);
    },
  );

  testWidgets(
    'a folder shows its own sites and All every site (WEBSPACE-002, WEBSPACE-004, WEBSPACE-009)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(2));
      expect(_inPanel(find.text('Work')), findsOneWidget);
      expect(_inPanel(find.text('2 sites')), findsOneWidget);
      expect(find.text('Site 2'), findsNothing);
      await tester.tap(find.text('Site 1'));
      expect(
        tester
            .state<_LibraryHarnessState>(find.byType(_LibraryHarness))
            .opened
            ?.name,
        'Site 1',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(WebspaceGroupTile), findsWidgets);
      await tester.tap(_group('All'));
      await tester.pumpAndSettle();
      expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(8));
    },
  );

  testWidgets(
    'webspace search finds sites by name and URL once across all groups (WEBSPACE-004)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      state.webspaces[2].siteIds.add(state.sites[0].siteId);
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      await _tapOutside(tester);
      final membership = {
        for (final group in state.webspaces) group.id: [...group.siteIds],
      };
      for (final query in ['  gItHuB  ', 'SITE0.EXAMPLE']) {
        await tester.enterText(find.byType(TextField), query);
        await tester.pumpAndSettle();
        expect(find.byType(WebspaceGroupTile), findsNothing);
        expect(find.byType(SiteGridTile), findsOneWidget);
        final result = tester.widget<SiteGridTile>(find.byType(SiteGridTile));
        expect(result.site, same(state.sites[0]));
        expect(result.webspaces.map((w) => w.name), ['Work', 'Privacy']);
        for (final group in result.webspaces) {
          expect(
            find.descendant(
              of: find.byType(SiteGridTile),
              matching: find.text(group.name),
            ),
            findsOneWidget,
          );
          expect(
            tester
                .widgetList<DecoratedBox>(
                  find.descendant(
                    of: find.byType(SiteGridTile),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .any(
                  (box) =>
                      (box.decoration as BoxDecoration).color ==
                      LibraryStyle.group(Brightness.light, id: group.id),
                ),
            isTrue,
          );
        }
        expect(result.onReorder, isNull);
        await tester.tap(find.text('GitHub'));
        expect(state.opened, same(state.sites[0]));
      }
      // Site 7 belongs to no named group and is outside the selected Work group.
      await tester.enterText(find.byType(TextField), 'site7.example');
      await tester.pumpAndSettle();
      expect(find.byType(SiteGridTile), findsOneWidget);
      expect(
        tester.widget<SiteGridTile>(find.byType(SiteGridTile)).webspaces,
        isEmpty,
      );
      await tester.tap(find.text('Site 7'));
      expect(state.opened, same(state.sites[7]));
      expect(state.selected, state.webspaces[1].id);
      expect({
        for (final group in state.webspaces) group.id: group.siteIds,
      }, membership);
      await tester.enterText(find.byType(TextField), 'no-such-site');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      expect(find.byType(WebspaceGroupTile), findsNothing);
      expect(find.byType(SiteGridTile), findsNothing);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(WebspaceGroupTile), findsNWidgets(4));
      expect(find.byType(SiteGridTile), findsNothing);
    },
  );

  testWidgets(
    'site results bound membership labels and expose all names (WEBSPACE-004)',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pumpLocalized(tester, home: const _LibraryHarness());
        await tester.pumpAndSettle();
        final state = tester.state<_LibraryHarnessState>(
          find.byType(_LibraryHarness),
        );
        state.webspaces[2].siteIds.add(state.sites[0].siteId);
        state.webspaces.last.siteIds.add(state.sites[0].siteId);
        state.webspaces.add(
          Webspace(name: 'Research', siteIds: [state.sites[0].siteId]),
        );
        await tester.enterText(find.byType(TextField), 'GitHub');
        await tester.pumpAndSettle();
        final result = find.byType(SiteGridTile);
        expect(result, findsOneWidget);
        expect(find.text('Work'), findsOneWidget);
        expect(find.text('Privacy'), findsOneWidget);
        expect(find.text('+2'), findsOneWidget);
        expect(find.text('Research'), findsNothing);
        expect(find.text(state.webspaces[3].name), findsNothing);
        expect(
          tester.getSemantics(result).getSemanticsData().label,
          contains('Work, Privacy, ${state.webspaces[3].name}, Research'),
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'webspace search shows matching groups and sites together, under an open folder (WEBSPACE-004)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      state.sites[2].name = 'Work chat';
      await tester.enterText(find.byType(TextField), 'wOrK');
      await tester.pumpAndSettle();
      expect(_group('Work'), findsOneWidget);
      expect(find.byType(WebspaceGroupTile), findsOneWidget);
      expect(find.byType(SiteGridTile), findsOneWidget);
      expect(find.text('Work chat'), findsOneWidget);
      expect(find.text('No matches'), findsNothing);
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(2));
      expect(_inPanel(find.text('Work chat')), findsNothing);
      await _tapOutside(tester);
      expect(find.text('Work chat').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'workspace management remains available without inline destructive actions (WEBSPACE-006, WEBSPACE-007)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await tester.longPress(_group('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      expect(state.edited, same(state.webspaces[1]));
      await tester.longPress(_group('All'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      await tester.tapAt(const Offset(780, 10));
      await tester.pumpAndSettle();
      await tester.longPress(_group('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(state.deleted, same(state.webspaces[1]));
    },
  );

  testWidgets('groups reorder directly from their item menu', (tester) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    await tester.longPress(_group('Work'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();
    final state = tester.state<_LibraryHarnessState>(
      find.byType(_LibraryHarness),
    );
    expect(state.webspaces.map((w) => w.name).take(3), [
      'All',
      'Privacy',
      'Work',
    ]);
  });

  testWidgets(
    'a long-pressed folder lifts: let go for its menu, drop it on another to move it (WEBSPACE-009)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      List<String> names() => [for (final w in state.webspaces) w.name];
      final before = names();
      final gesture = await tester.startGesture(
        tester.getCenter(_group('Work')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Work'),
        findsNWidgets(2),
        reason: 'the lifted copy rides under the finger',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      await tester.tapAt(const Offset(780, 10));
      await tester.pumpAndSettle();
      expect(names(), before);
      await _lift(tester, from: _group('Privacy'), to: _group('Work'));
      expect(find.text('Edit'), findsNothing, reason: 'a drag opens no menu');
      expect(names().take(3), ['All', 'Privacy', 'Work']);
      await _lift(tester, from: _group('Work'), to: _group('All'));
      await _lift(tester, from: _group('All'), to: _group('Work'));
      expect(names().take(3), ['All', 'Privacy', 'Work']);
      await tester.enterText(find.byType(TextField), 'r');
      await tester.pumpAndSettle();
      await _lift(tester, from: _group('Work'), to: _group('Privacy'));
      expect(names().take(3), [
        'All',
        'Privacy',
        'Work',
      ], reason: 'a filtered grid does not reorder');
    },
  );

  testWidgets('a slow tap, let go before the lift, still opens a site', (
    tester,
  ) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    final state = tester.state<_LibraryHarnessState>(
      find.byType(_LibraryHarness),
    );
    await tester.tap(_group('Work'));
    await tester.pumpAndSettle();
    final press = await tester.startGesture(
      tester.getCenter(find.text('GitHub')),
    );
    await tester.pump(const Duration(milliseconds: 420));
    await press.up(timeStamp: const Duration(milliseconds: 420));
    await tester.pumpAndSettle();
    expect(state.opened, same(state.sites[0]));
    expect(state.menuFor, isNull);
  });

  testWidgets(
    'a long-pressed site in a folder lifts: let go for its menu, drop it on another to move it (WEBSPACE-011)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await _lift(tester, from: find.text('GitHub'));
      expect(state.menuFor, same(state.sites[0]));
      expect(state.siteMoves, isEmpty);
      expect(_panel, findsOneWidget);
      await _lift(tester, from: find.text('GitHub'), to: find.text('Site 1'));
      expect(state.siteMoves, [(0, 1)]);
      expect(state.opened, isNull);
      expect(_panel, findsOneWidget, reason: 'a drag keeps the folder open');
    },
  );

  testWidgets(
    'icons the grid moves slide there from their old place, with no flash at the new one (WEBSPACE-011)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final before = _well(tester, name: 'Work');
      final privacy = _well(tester, name: 'Privacy');
      await tester.longPress(_group('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pump();
      expect(
        _well(tester, name: 'Work'),
        before,
        reason: 'the first frame after the move still shows it where it was',
      );
      await tester.pump();
      await tester.pump(Motion.settle ~/ 3);
      final sliding = _well(tester, name: 'Work').center;
      expect(sliding.dx, greaterThan(before.center.dx));
      expect(sliding.dx, lessThan(privacy.center.dx));
      await tester.pumpAndSettle();
      expect(_well(tester, name: 'Work'), privacy);
      expect(_well(tester, name: 'Privacy'), before);
    },
  );

  testWidgets('a dropped icon lands from where it was let go', (tester) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    final work = _well(tester, name: 'Work');
    final privacy = _well(tester, name: 'Privacy');
    final drag = await tester.startGesture(privacy.center);
    await tester.pump(const Duration(milliseconds: 600));
    final release = work.center + const Offset(0, 30);
    await drag.moveTo(release);
    await tester.pump();
    await drag.up();
    await tester.pump();
    await tester.pump();
    final landing = _well(tester, name: 'Privacy').center;
    expect(
      (landing - release).distance,
      lessThan((landing - work.center).distance + 1),
    );
    expect(
      (landing - privacy.center).distance,
      greaterThan(work.width),
      reason: 'it lands from the drop, not from where the drag began',
    );
    await tester.pumpAndSettle();
    expect(_well(tester, name: 'Privacy'), work);
  });

  testWidgets('scrolling a grid never slides its icons', (tester) async {
    await pumpLocalized(
      tester,
      home: const _LibraryHarness(),
      size: const Size(411, 600),
    );
    await tester.pumpAndSettle();
    await tester.tap(_group('All'));
    await tester.pumpAndSettle();
    final tile = _inPanel(find.byType(SiteGridTile)).at(4);
    final before = tester.getRect(tile);
    final grid = _inPanel(find.byType(CustomScrollView));
    await tester.drag(grid, const Offset(0, -60));
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: grid, matching: find.byType(Scrollable)),
    );
    expect(
      tester.getRect(tile),
      before.shift(Offset(0, -scrollable.position.pixels)),
    );
  });

  testWidgets('a search crossfades in and out of the groups', (tester) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'github');
    await tester.pump();
    await tester.pump(Motion.reveal ~/ 2);
    final fades = tester
        .widgetList<FadeTransition>(
          find.descendant(
            of: find.byType(AnimatedSwitcher),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((f) => f.opacity.value);
    expect(fades.any((o) => o > 0 && o < 1), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(WebspaceGroupTile), findsNothing);
    expect(find.byType(SiteGridTile), findsOneWidget);
  });

  for (final width in [320.0, 411.0, 800.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'folder and site grids at $width, ${scale}x, ${brightness.name} (DESIGN-006)',
          (tester) async {
            setViewSize(tester, size: Size(width, 800));
            await tester.pumpWidget(
              localizedApp(
                MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 800),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: const _LibraryHarness(),
                ),
                theme: ThemeData(
                  colorScheme: buildAccentColorScheme(
                    accentBlue,
                    brightness: brightness,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.scrollUntilVisible(
              _group('Work'),
              200,
              scrollable: find
                  .descendant(
                    of: find.byKey(const PageStorageKey('webspace-groups')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.tap(_group('Work'));
            await tester.pumpAndSettle();
            expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(2));
            expect(tester.takeException(), isNull);
            await _tapOutside(tester);
            final state = tester.state<_LibraryHarnessState>(
              find.byType(_LibraryHarness),
            );
            state.webspaces[1].name = state.webspaces.last.name;
            state.webspaces[2].siteIds.add(state.sites[0].siteId);
            state.webspaces.last.siteIds.add(state.sites[0].siteId);
            await tester.enterText(find.byType(TextField), 'site0.example');
            await tester.pumpAndSettle();
            expect(find.byType(SiteGridTile), findsOneWidget);
            expect(find.text('+1'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('a folder opens and searches right-to-left', (tester) async {
    await pumpLocalized(
      tester,
      home: const _LibraryHarness(),
      locale: const Locale('ar'),
      size: const Size(393, 852),
    );
    await tester.pumpAndSettle();
    expect(
      Directionality.of(tester.element(find.byType(WebspaceLibrary))),
      TextDirection.rtl,
    );
    final well = _well(tester, name: 'Work');
    await tester.tap(_group('Work'));
    await tester.pump();
    expect(tester.getRect(_panel), well);
    await tester.pump(const Duration(milliseconds: 50));
    final entering = tester.getRect(_panel);
    await tester.pumpAndSettle();
    expect(_inPanel(find.byType(SiteGridTile)), findsNWidgets(2));
    expect(entering.width, lessThan(tester.getRect(_panel).width));
    expect(tester.takeException(), isNull);
  });
}
