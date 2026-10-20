import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webspace/screens/add_site.dart' show UnifiedFaviconImage;
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/webspace_folder_tile.dart';
import 'helpers/localized.dart';

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
      ),
    );
  }
}

Finder _folder(String name) => find.descendant(
  of: find.byType(WebspaceFolderTile),
  matching: find.text(name),
);

void main() {
  testWidgets(
    'folders preview the live members and count the hidden sites (WEBSPACE-003)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      expect(find.text('+5'), findsOneWidget);
      final all = find.byWidgetPredicate(
        (widget) => widget is WebspaceFolderTile && widget.webspace.isAll,
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
      await tester.tap(_folder('Work'));
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
      expect(find.byType(WebspaceFolderTile), findsWidgets);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('Sites'));
      await tester.pumpAndSettle();
      expect(find.byType(SiteGridTile), findsNWidgets(8));
    },
  );

  testWidgets(
    'workspace management remains available without inline destructive actions (WEBSPACE-006, WEBSPACE-007)',
    (tester) async {
      await pumpLocalized(tester, home: const _LibraryHarness());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await tester.longPress(_folder('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final state = tester.state<_LibraryHarnessState>(
        find.byType(_LibraryHarness),
      );
      expect(state.edited, same(state.webspaces[1]));
      await tester.longPress(_folder('All'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      await tester.tapAt(const Offset(780, 10));
      await tester.pumpAndSettle();
      await tester.longPress(_folder('Work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(state.deleted, same(state.webspaces[1]));
    },
  );

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
              _folder('Work'),
              200,
              scrollable: find
                  .descendant(
                    of: find.byKey(const PageStorageKey('webspace-folders')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.tap(_folder('Work'));
            await tester.pumpAndSettle();
            expect(find.byType(SiteGridTile), findsNWidgets(2));
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
    await tester.tap(_folder('Work'));
    await tester.pumpAndSettle();
    expect(find.byType(SiteGridTile), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
