import 'dart:typed_data';
import 'package:flutter/material.dart';
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
import 'package:webspace/widgets/tabs_sheet.dart';
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

  @override
  Widget build(BuildContext context) {
    WebspaceSelectionEngine.resolveIndices(
      webspaces,
      siteIdsByPosition: [for (final site in sites) site.siteId],
    );
    return Scaffold(
      body: WebspaceLibrary(
        key: library,
        webspaces: webspaces,
        sites: sites,
        selectedWebspaceId: selected,
        currentSite: null,
        showsTabCount: (site) => site.effectiveTabsEnabled,
        onSelectWebspace: (webspace) {
          setState(() => selected = webspace.id);
          library.currentState!.showSelectedWebspace();
        },
        onAddWebspace: () {},
        onEditWebspace: (webspace) => edited = webspace,
        onDeleteWebspace: (webspace) => deleted = webspace,
        onReorder: (from, {required newIndex}) => setState(() {
          WebspaceSelectionEngine.reorder(webspaces, from: from, to: newIndex);
        }),
        onOpenSite: (site) => opened = site,
        onSiteMenu: (context, {required site, required position}) {},
        onReorderSite: null,
        onAddSite: () {},
        onOpenSettings: () async {},
        siteTreeBuilder: (context, {required query}) => TabsSheet(
          embedded: true,
          query: query,
          sites: [
            for (final site in sites)
              TabsSheetSite(model: site, isCurrent: false, isLoaded: false),
          ],
          currentIndex: 0,
          onOpenSite: (site) => opened = site,
          onOpenTab: (site, {required tabId}) => opened = site,
          onNewTab: (_) {},
          onCloseTab: (_, {required tabId}) {},
          onCloseSubtree: (_, {required tabId}) {},
        ),
      ),
    );
  }
}

Finder _group(String name) => find.descendant(
  of: find.byType(WebspaceGroupTile),
  matching: find.text(name),
);

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
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
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

  for (final (direction, sign) in [
    (TextDirection.ltr, 1.0),
    (TextDirection.rtl, -1.0),
  ]) {
    for (final fast in [false, true]) {
      testWidgets(
        '${direction.name} ${fast ? 'fling' : 'swipe'} returns to groups and clears search',
        (tester) async {
          await pumpLocalized(
            tester,
            home: Directionality(
              textDirection: direction,
              child: const _LibraryHarness(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(_group('Work'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'GitHub');
          await tester.pumpAndSettle();
          final state = tester.state<_LibraryHarnessState>(
            find.byType(_LibraryHarness),
          );
          final membership = [...state.webspaces[1].siteIds];
          final start = tester.getCenter(find.byType(SiteGridTile).first);
          if (fast) {
            await tester.flingFrom(start, Offset(50 * sign, 0), 1000);
          } else {
            await tester.timedDragFrom(
              start,
              Offset(180 * sign, 0),
              const Duration(milliseconds: 800),
            );
          }
          await tester.pumpAndSettle();
          expect(_group('Work').hitTestable(), findsOneWidget);
          expect(find.byType(SiteGridTile), findsNothing);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            isEmpty,
          );
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText))
                .focusNode
                .hasFocus,
            isFalse,
          );
          expect(state.selected, state.webspaces[1].id);
          expect(state.webspaces[1].siteIds, membership);
          expect(state.opened, isNull);
        },
      );
    }
  }

  testWidgets('an empty group accepts a back swipe', (tester) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    final state = tester.state<_LibraryHarnessState>(
      find.byType(_LibraryHarness),
    );
    await tester.tap(_group(state.webspaces.last.name));
    await tester.pumpAndSettle();
    expect(find.byType(SiteGridTile), findsNothing);
    await tester.timedDragFrom(
      tester.getCenter(find.byType(WebspaceLibrary)),
      const Offset(180, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(_group('Work').hitTestable(), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets(
    'scrolling, wrong-way, short and cancelled drags keep a group open',
    (tester) async {
      await pumpLocalized(
        tester,
        home: const _LibraryHarness(),
        size: const Size(411, 600),
      );
      await tester.pumpAndSettle();
      await tester.tap(_group('All'));
      await tester.pumpAndSettle();
      final grid = find.byType(CustomScrollView);
      await tester.drag(grid, const Offset(0, -150));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, greaterThan(0));
      final start = tester.getCenter(grid);
      await tester.flingFrom(start, const Offset(-150, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      final cancelled = await tester.startGesture(start);
      await cancelled.moveBy(const Offset(100, 0));
      await cancelled.moveBy(const Offset(80, 0));
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.timedDragFrom(
        start,
        const Offset(40, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(WebspaceGroupTile), findsNothing);
      expect(
        tester.state<_LibraryHarnessState>(find.byType(_LibraryHarness)).opened,
        isNull,
      );
    },
  );

  testWidgets('group expansion and collapse remain visible at normal speed', (
    tester,
  ) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    await tester.tap(_group('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final expanding = tester.getRect(find.byType(SiteGridTile).first).width;
    await tester.pumpAndSettle();
    final expanded = tester.getRect(find.byType(SiteGridTile).first).width;
    expect(
      expanding,
      lessThan(expanded * .95),
      reason: 'the expansion should still be visible after the tap',
    );
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final collapsing = tester.getRect(_group('Work')).width;
    await tester.pumpAndSettle();
    final collapsed = tester.getRect(_group('Work')).width;
    expect(
      collapsing,
      greaterThan(collapsed * 1.05),
      reason: 'closing should visibly settle back into the group grid',
    );
  });

  testWidgets('group navigation never fades both pages to an empty frame', (
    tester,
  ) async {
    await pumpLocalized(tester, home: const _LibraryHarness());
    await tester.pumpAndSettle();
    await tester.tap(_group('Work'));
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
      final outgoing = tester.widget<FadeTransition>(
        find
            .ancestor(of: _group('Work'), matching: find.byType(FadeTransition))
            .first,
      );
      final incoming = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byType(SiteGridTile).first,
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(
        outgoing.opacity.value + incoming.opacity.value,
        greaterThan(.9),
        reason: 'the launcher remains visible throughout opening',
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
      final outgoing = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byType(SiteGridTile).first,
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final incoming = tester.widget<FadeTransition>(
        find
            .ancestor(of: _group('Work'), matching: find.byType(FadeTransition))
            .first,
      );
      expect(
        outgoing.opacity.value + incoming.opacity.value,
        greaterThan(.9),
        reason: 'the launcher remains visible throughout closing',
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets(
    'folder navigation keeps chrome steady and accepts Back mid-transition',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      final search = tester.getRect(find.byType(TextField));
      final navigation = tester.getRect(find.text('Settings'));
      await tester.tap(_group('Work'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(WebspaceGroupTile).hitTestable(), findsNothing);
      expect(tester.getRect(find.byType(TextField)), search);
      expect(tester.getRect(find.text('Settings')), navigation);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_group('Work').hitTestable(), findsOneWidget);
      expect(find.byType(SiteGridTile), findsNothing);
      expect(tester.getRect(find.byType(TextField)), search);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion opens and closes a folder without overlapping pages',
    (tester) async {
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
      expect(find.byType(WebspaceGroupTile), findsNothing);
      expect(find.byType(SiteGridTile).hitTestable(), findsNWidgets(2));
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.byType(SiteGridTile), findsNothing);
      expect(_group('Work').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    'opening a folder filters sites, search clears on back, and All stays complete (WEBSPACE-002, WEBSPACE-004, WEBSPACE-009)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      await tester.tap(_group('Work'));
      await tester.pumpAndSettle();
      expect(find.byType(SiteGridTile), findsNWidgets(2));
      expect(find.text('Site 2'), findsNothing);
      await tester.enterText(find.byType(TextField), 'site1.example');
      await tester.pumpAndSettle();
      expect(find.byType(SiteGridTile), findsOneWidget);
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
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('Sites'));
      await tester.pumpAndSettle();
      expect(find.byType(SiteGridTile), findsNothing);
      expect(find.byType(TabsSheet), findsOneWidget);
      expect(
        tester.widget<TabsSheet>(find.byType(TabsSheet)).sites,
        hasLength(8),
      );
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
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
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
    'webspace search shows matching groups and sites together (WEBSPACE-004)',
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
      expect(find.byType(WebspaceGroupTile), findsNothing);
      expect(find.byType(SiteGridTile), findsNWidgets(2));
      expect(find.text('Work chat'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
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
            expect(find.byType(SiteGridTile), findsNWidgets(2));
            await tester.tap(find.text('Sites'));
            await tester.pumpAndSettle();
            expect(find.byType(TabsSheet), findsOneWidget);
            await tester.tap(find.text('Webspaces').last);
            await tester.pumpAndSettle();
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

  testWidgets('folder drill-down and search render right-to-left', (
    tester,
  ) async {
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
    await tester.tap(_group('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final entering = tester.getRect(find.byType(SiteGridTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(SiteGridTile), findsNWidgets(2));
    expect(
      entering.width,
      lessThan(tester.getRect(find.byType(SiteGridTile).first).width),
    );
    expect(tester.takeException(), isNull);
  });
}
