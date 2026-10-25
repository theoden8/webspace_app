import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/container_mark.dart';
import 'package:webspace/widgets/launch_zoom.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';
import 'helpers/real_app.dart';
import 'helpers/group_tile.dart';

/// [name]'s icon in the open folder, not its preview on the folder tile.
Finder _siteTile(String name) => find.byWidgetPredicate(
  (widget) => widget is SiteGridTile && widget.site.name == name,
);

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));
  tearDown(ConnectivityService.reset);
  testWidgets(
    'workspace colors survive edits, reordering and settings restore',
    (tester) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final work = Webspace(
        id: WebspaceId('workspace-work'),
        name: 'Work',
        siteIds: [alpha.siteId],
      );
      final personal = Webspace(
        id: WebspaceId('workspace-personal'),
        name: 'Personal',
      );
      final prefsValues = <String, Object>{
        AppPref.developerMode.key: true,
        AppPref.experimentalFolderLibrary.key: true,
      };
      await pumpRealApp(
        tester,
        sites: [alpha],
        webspaces: [work, personal],
        prefs: prefsValues,
      );
      final colors = {
        for (final id in [WebspaceId.all, work.id, personal.id])
          id: groupBackground(tester, id: id),
      };
      await openWebspace(tester, name: 'Work');
      await pressBack(tester);
      final drag = await tester.startGesture(tester.getCenter(find.text('Work')));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(find.text('Personal')));
      await tester.pump();
      await drag.up();
      await settleRealApp(tester);
      final saved = (await SharedPreferences.getInstance())
          .getStringList('webspaces')!
          .map((raw) => (jsonDecode(raw) as Map<String, dynamic>)['name'])
          .toList();
      expect(saved, ['All', 'Personal', 'Work'], reason: 'dragged into place');
      for (final entry in colors.entries) {
        expect(groupBackground(tester, id: entry.key), entry.value);
      }
      await tester.longPress(find.text('Work'));
      await settleRealApp(tester);
      await tester.tap(find.text('Edit'));
      await settleRealApp(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Webspace Name'),
        'Projects',
      );
      await tester.tap(find.bySemanticsLabel('Save'));
      await settleRealApp(tester);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'Projects',
      );
      await tester.pumpAndSettle();
      expect(groupBackground(tester, id: work.id), colors[work.id]);
      final prefs = await SharedPreferences.getInstance();
      final restored = prefs
          .getStringList('webspaces')!
          .map(
            (raw) => Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          )
          .singleWhere((group) => group.id == work.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleRealApp(tester);
      await pumpRealApp(
        tester,
        sites: [alpha],
        webspaces: [
          restored,
          Webspace(name: 'Added'),
        ],
        prefs: {...prefsValues, 'selectedWebspaceId': work.id},
      );
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Personal'), findsNothing);
      expect(groupBackground(tester, id: work.id), colors[work.id]);
      expect(
        groupBackground(tester, id: WebspaceId.all),
        colors[WebspaceId.all],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('webspace search opens a site outside the selected group', (
    tester,
  ) async {
    final alpha = WebViewModel(
      initUrl: 'https://alpha.example.test',
      name: 'Alpha',
    );
    final beta = WebViewModel(
      initUrl: 'https://beta.example.test',
      name: 'Beta',
    );
    final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
    await pumpRealApp(
      tester,
      sites: [alpha, beta],
      webspaces: [work],
      prefs: {
        AppPref.developerMode.key: true,
        AppPref.experimentalFolderLibrary.key: true,
        'selectedWebspaceId': work.id,
      },
    );
    final prefs = await SharedPreferences.getInstance();
    final savedGroups = prefs.getStringList('webspaces');
    final savedSites = prefs.getStringList('webViewModels');
    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      'BETA.EXAMPLE',
    );
    await tester.pumpAndSettle();
    expect(find.byType(WebspaceGroupTile), findsNothing);
    expect(find.byType(SiteGridTile), findsOneWidget);
    await tester.tap(find.text('Beta'));
    await settleRealApp(tester);
    expect(find.byType(WebspaceLibrary), findsNothing);
    expect(prefs.getInt('currentIndex'), 1);
    expect(prefs.getString('selectedWebspaceId'), work.id);
    expect(prefs.getStringList('webspaces'), savedGroups);
    expect(prefs.getStringList('webViewModels'), savedSites);
    await tester.tap(find.byTooltip('Back to Webspaces'));
    await settleRealApp(tester);
    expect(find.byType(WebspaceLibrary), findsOneWidget);
    expect(find.byKey(const ValueKey('library-folder')), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.byType(SiteGridTile), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final enabled in [false, true]) {
    testWidgets('browser navigation follows Alternative design=$enabled', (
      tester,
    ) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final beta = WebViewModel(
        initUrl: 'https://beta.example.test',
        name: 'Beta',
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha, beta],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: enabled,
        },
      );
      await openWebspace(tester, name: 'Work');
      await openSiteFromDrawer(tester, name: 'Alpha');
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold).first).hasDrawer,
        !enabled,
      );
      expect(
        find.byType(DrawerButton),
        enabled ? findsNothing : findsOneWidget,
      );
      if (enabled) {
        await tester.tap(find.byTooltip('Back to Webspaces'));
        await settleRealApp(tester);
        expect(find.byType(WebspaceLibrary), findsOneWidget);
        expect(find.byType(SiteGridTile), findsOneWidget);
        expect(find.text('Beta'), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('selectedWebspaceId'), work.id);
      } else {
        await tester.tap(find.byTooltip('Open navigation menu'));
        await settleRealApp(tester);
        expect(find.byType(SiteDrawer), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Back opens the matching navigation with Alternative design=$enabled',
      (tester) async {
        final alpha = WebViewModel(
          initUrl: 'https://alpha.example.test',
          name: 'Alpha',
        );
        final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
        await pumpRealApp(
          tester,
          sites: [alpha],
          webspaces: [work],
          prefs: {
            AppPref.developerMode.key: true,
            AppPref.experimentalFolderLibrary.key: enabled,
            AppPref.backOpensMenu.key: true,
          },
        );
        await openWebspace(tester, name: 'Work');
        await openSiteFromDrawer(tester, name: 'Alpha');
        await pressBack(tester);
        expect(
          find.byType(WebspaceLibrary),
          enabled ? findsOneWidget : findsNothing,
        );
        expect(
          tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
          !enabled,
        );
        if (enabled) expect(find.byType(SiteGridTile), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      skip: hostIsIOS || hostIsMacOS,
    );
  }

  testWidgets('Alternative design keeps the default Back behavior while browsing', (
    tester,
  ) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(initUrl: 'https://alpha.example.test', name: 'Alpha'),
      ],
      prefs: {
        AppPref.developerMode.key: true,
        AppPref.experimentalFolderLibrary.key: true,
        AppPref.backOpensMenu.key: false,
      },
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Alpha');
    await pressBack(tester);
    expect(find.byType(WebspaceLibrary), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(DrawerButton), findsNothing);
    expect(
      tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
      isFalse,
    );
  });

  testWidgets(
    'reordering sites in a folder keeps it open and saves the order (WEBSPACE-011); Back closes it',
    (tester) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final beta = WebViewModel(
        initUrl: 'https://beta.example.test',
        name: 'Beta',
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId, beta.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha, beta],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await openWebspace(tester, name: 'Work');
      final alphaTile = _siteTile('Alpha');
      final betaTile = _siteTile('Beta');
      final drag = await tester.startGesture(tester.getCenter(alphaTile));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(betaTile));
      await tester.pump();
      await drag.up();
      await settleRealApp(tester);
      expect(find.byKey(const ValueKey('library-folder')), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs
          .getStringList('webspaces')!
          .map(
            (raw) => Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          )
          .singleWhere((group) => group.id == work.id);
      expect(saved.siteIds, [beta.siteId, alpha.siteId]);
      await pressBack(tester);
      expect(find.byKey(const ValueKey('library-folder')), findsNothing);
      expect(find.byType(WebspaceGroupTile).hitTestable(), findsNWidgets(2));
      expect(find.byType(SiteGridTile), findsNothing);
      expect(prefs.getString('selectedWebspaceId'), work.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    "a site's Edit dialog puts it in the webspaces chosen there (EDIT-011)",
    (tester) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final beta = WebViewModel(
        initUrl: 'https://beta.example.test',
        name: 'Beta',
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId, beta.siteId]);
      final reading = Webspace(name: 'Reading', siteIds: [beta.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha, beta],
        webspaces: [work, reading],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await openWebspace(tester, name: 'Work');
      await tester.longPress(_siteTile('Alpha'));
      await settleRealApp(tester);
      await tester.tap(find.text('Edit'));
      await settleRealApp(tester);
      await tester.tap(find.widgetWithText(FilterChip, 'Work'));
      await tester.tap(find.widgetWithText(FilterChip, 'Reading'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settleRealApp(tester);
      final prefs = await SharedPreferences.getInstance();
      final saved = {
        for (final raw in prefs.getStringList('webspaces')!)
          if (Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>)
              case final group when !group.isAll)
            group.name: group.siteIds,
      };
      expect(saved, {
        'Work': [beta.siteId],
        'Reading': [beta.siteId, alpha.siteId],
      });
      expect(find.byType(SiteGridTile), findsOneWidget,
          reason: 'Alpha left the group on screen');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a look-alike site\'s card opens in its container colour, as its icon is (WEBSPACE-014)',
    (tester) async {
      final icon = Uint8List.fromList(
        image.encodePng(image.Image(width: 3, height: 2)),
      );
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
        customIconPng: icon,
      )..containerColor = 3;
      final beta = WebViewModel(
        initUrl: 'https://beta.example.test',
        name: 'Beta',
        customIconPng: icon,
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha, beta],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await openWebspace(tester, name: 'Work');
      await tester.tap(_siteTile('Alpha'));
      await tester.pump();
      final card = find.descendant(
        of: find.byType(LaunchZoom),
        matching: find.byType(Material),
      );
      final theme = Theme.of(tester.element(card));
      expect(
        tester.widget<Material>(card).color,
        SiteGridTile.wellColor(
          containerColorOf(alpha, brightness: theme.brightness),
          theme: theme,
        ),
        reason: 'Beta shows the same icon, outside the folder',
      );
      await settleRealApp(tester);
    },
  );

  testWidgets(
    'a site grows out of its icon in the folder and shrinks back into it (WEBSPACE-008)',
    (tester) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await openWebspace(tester, name: 'Work');
      final card = find.descendant(
        of: find.byType(LaunchZoom),
        matching: find.byType(Material),
      );
      // The well the tile draws, as a grid's icon or a row's.
      final icon = tester.getRect(
        find.descendant(
          of: _siteTile('Alpha'),
          matching: find.byType(AnimatedContainer),
        ),
      );
      await tester.tap(_siteTile('Alpha'));
      await tester.pump();
      expect(tester.getRect(card), icon);
      expect(
        find.byType(WebspaceLibrary),
        findsOneWidget,
        reason: 'the folder stays on screen while the card grows',
      );
      await settleRealApp(tester);
      expect(card, findsNothing);
      expect(find.byType(WebspaceLibrary), findsNothing);
      await tester.tap(find.byTooltip('Back to Webspaces'));
      await tester.pump();
      expect(
        tester.getRect(card).size,
        tester.getSize(find.byType(LaunchZoom)),
        reason: 'a full card covers the switch back',
      );
      await settleRealApp(tester);
      expect(card, findsNothing);
      expect(find.byKey(const ValueKey('library-folder')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the library tab tree opens a nested tab on its site (WEBSPACE-004)', (
    tester,
  ) async {
    final root = SiteTab(
      id: TabId('root'),
      url: 'https://alpha.example.test',
      title: 'Overview',
    );
    final child = SiteTab(
      id: TabId('child'),
      parentId: root.id,
      url: 'https://alpha.example.test/article',
      title: 'Deep article',
    );
    final site = WebViewModel(
      initUrl: root.url,
      name: 'Alpha',
      tabsEnabled: true,
      tabs: [root, child],
      activeTabId: root.id,
    );
    await pumpRealApp(
      tester,
      sites: [site],
      prefs: {
        AppPref.developerMode.key: true,
        AppPref.experimentalFolderLibrary.key: true,
      },
    );
    await tester.tap(find.byTooltip('Tabs'));
    await settleRealApp(tester);
    expect(find.byType(TabsSheet), findsOneWidget);
    await tester.tap(find.text('Deep article'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(LaunchZoom),
        matching: find.byType(Material),
      ),
      findsOneWidget,
      reason: 'a tab picked in a list opens through its site\'s card too',
    );
    await settleRealApp(tester);
    expect(appSite('Alpha').activeTabId, child.id);
    expect(find.byType(WebspaceLibrary), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (dev, on) in [
    (false, false),
    (false, true),
    (true, false),
    (true, true),
  ]) {
    testWidgets('folder library gate: developer=$dev switch=$on', (
      tester,
    ) async {
      await pumpRealApp(
        tester,
        sites: [],
        prefs: {
          AppPref.developerMode.key: dev,
          AppPref.experimentalFolderLibrary.key: on,
        },
      );
      final enabled = dev && on;
      expect(
        find.byType(WebspaceLibrary),
        enabled ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(WebspacesListScreen),
        enabled ? findsNothing : findsOneWidget,
      );
      expect(find.byType(AppBar), enabled ? findsNothing : findsOneWidget);
      expect(
        find.byType(FloatingActionButton),
        enabled ? findsNothing : findsOneWidget,
      );
      if (!enabled) {
        await openWebspace(tester, name: 'All');
        expect(
          tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
          isTrue,
        );
      }
    });
  }

  testWidgets('folder library follows switches live and remembers its opt-in', (
    tester,
  ) async {
    await pumpRealApp(
      tester,
      sites: [],
      prefs: {AppPref.developerMode.key: true},
    );
    expect(find.byType(WebspacesListScreen), findsOneWidget);
    await ExperimentalFeaturesService.instance.setSwitch(
      ExperimentalFeature.folderLibrary,
      on: true,
    );
    await settleRealApp(tester);
    expect(find.byType(WebspaceLibrary), findsOneWidget);
    await DeveloperModeService.instance.setEnabled(on: false);
    await settleRealApp(tester);
    expect(find.byType(WebspacesListScreen), findsOneWidget);
    expect(
      ExperimentalFeaturesService.instance.switchOn(
        ExperimentalFeature.folderLibrary,
      ),
      isTrue,
    );
    await DeveloperModeService.instance.setEnabled(on: true);
    await settleRealApp(tester);
    expect(find.byType(WebspaceLibrary), findsOneWidget);
    await ExperimentalFeaturesService.instance.setSwitch(
      ExperimentalFeature.folderLibrary,
      on: false,
    );
    await settleRealApp(tester);
    expect(find.byType(WebspacesListScreen), findsOneWidget);
  });

  testWidgets(
    'selecting a folder, or swiping to another in it, persists its scope and opens sites without a drawer (WEBSPACE-002, WEBSPACE-004, WEBSPACE-008)',
    (tester) async {
      final portal = WebViewModel(
        initUrl: 'https://portal.example.test',
        name: 'Portal',
      );
      final other = WebViewModel(
        initUrl: 'https://other.example.test',
        name: 'Other',
      );
      final work = Webspace(name: 'Work', siteIds: [portal.siteId]);
      await pumpRealApp(
        tester,
        sites: [portal, other],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await openWebspace(tester, name: 'Work');
      expect(find.byType(SiteGridTile), findsOneWidget);
      expect(find.text('Portal'), findsOneWidget);
      expect(find.text('Other'), findsNothing);
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold).first).isDrawerOpen,
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('selectedWebspaceId'), work.id);
      final folder = find.byKey(const ValueKey('library-folder'));
      await tester.fling(folder, const Offset(300, 0), 1000);
      await settleRealApp(tester);
      expect(find.byType(SiteGridTile), findsNWidgets(2));
      expect(prefs.getString('selectedWebspaceId'), WebspaceId.all);
      await pressBack(tester);
      expect(folder, findsNothing);
      expect(find.byType(WebspaceGroupTile).hitTestable(), findsNWidgets(2));
    },
  );

  testWidgets(
    'a site added from the home joins the webspaces picked for it, and one added in a folder starts in it (EDIT-012)',
    (tester) async {
      final portal = WebViewModel(
        initUrl: 'https://portal.example.test',
        name: 'Portal',
      );
      final work = Webspace(name: 'Work', siteIds: [portal.siteId]);
      final personal = Webspace(name: 'Personal', siteIds: []);
      await pumpRealApp(
        tester,
        sites: [portal],
        webspaces: [work, personal],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      Finder chip(String name) => find.widgetWithText(FilterChip, name);
      await openWebspace(tester, name: 'Work');
      await tester.tap(find.byTooltip('Add Site'));
      await settleRealApp(tester);
      expect(tester.widget<FilterChip>(chip('Work')).selected, isTrue);
      expect(tester.widget<FilterChip>(chip('Personal')).selected, isFalse);
      await tester.pageBack();
      await settleRealApp(tester);
      await pressBack(tester);
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Site'));
      await settleRealApp(tester);
      expect(tester.widget<FilterChip>(chip('Work')).selected, isFalse);
      expect(chip('All'), findsNothing);
      await tester.tap(chip('Personal'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Enter URL'),
        'https://new.example.test',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add Site'));
      await settleRealApp(tester);
      final prefs = await SharedPreferences.getInstance();
      final added = [
        for (final raw in prefs.getStringList('webViewModels')!)
          jsonDecode(raw) as Map<String, dynamic>,
      ].singleWhere((site) => site['initUrl'] == 'https://new.example.test');
      final saved = {
        for (final raw in prefs.getStringList('webspaces')!)
          (jsonDecode(raw) as Map<String, dynamic>)['name']:
              (jsonDecode(raw) as Map<String, dynamic>)['siteIds'],
      };
      expect(saved['Personal'], [added['siteId']]);
      expect(saved['Work'], [portal.siteId]);
    },
  );

  testWidgets(
    'editing a folder updates membership, previews, and persisted ids (WEBSPACE-006)',
    (tester) async {
      final first = WebViewModel(
        initUrl: 'https://first.example.test',
        name: 'First',
      );
      final second = WebViewModel(
        initUrl: 'https://second.example.test',
        name: 'Second',
      );
      final work = Webspace(name: 'Work', siteIds: [first.siteId]);
      await pumpRealApp(
        tester,
        sites: [first, second],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await tester.longPress(find.text('Work'));
      await settleRealApp(tester);
      await tester.tap(find.text('Edit'));
      await settleRealApp(tester);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'First'));
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Second'));
      await tester.tap(find.bySemanticsLabel('Save'));
      await settleRealApp(tester);
      final folder = tester
          .widgetList<WebspaceGroupTile>(find.byType(WebspaceGroupTile))
          .singleWhere((tile) => tile.webspace.id == work.id);
      expect(folder.sites.map((site) => site.name), ['Second']);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs
          .getStringList('webspaces')!
          .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
          .singleWhere((value) => value['id'] == work.id);
      expect(saved['siteIds'], [second.siteId]);
    },
  );

  testWidgets(
    'a glyph picked in a webspace\'s editor leads its name and is saved; No '
    'icon takes it off (WEBSPACE-016)',
    (tester) async {
      final alpha = WebViewModel(
        initUrl: 'https://alpha.example.test',
        name: 'Alpha',
      );
      final work = Webspace(name: 'Work', siteIds: [alpha.siteId]);
      await pumpRealApp(
        tester,
        sites: [alpha],
        webspaces: [work],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      Future<Map<String, dynamic>> saved() async =>
          (await SharedPreferences.getInstance())
              .getStringList('webspaces')!
              .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
              .singleWhere((value) => value['id'] == work.id);
      final workTile = find.byWidgetPredicate(
        (widget) => widget is WebspaceGroupTile && widget.webspace.id == work.id,
      );
      Future<void> edit(Future<void> Function() pick) async {
        await tester.longPress(workTile);
        await settleRealApp(tester);
        await tester.tap(find.text('Edit'));
        await settleRealApp(tester);
        await tester.tap(find.text('Icon'));
        await settleRealApp(tester);
        await pick();
        await settleRealApp(tester);
        await tester.tap(find.bySemanticsLabel('Save'));
        await settleRealApp(tester);
      }

      await edit(() => tester.tap(find.byTooltip('Code')));
      expect(
        find.descendant(
          of: find.byType(WebspaceGroupTile),
          matching: find.byIcon(Icons.code),
        ),
        findsOneWidget,
      );
      expect((await saved())['icon'], 'code');

      await edit(() => tester.tap(find.text('No icon')));
      expect(find.byIcon(Icons.code), findsNothing);
      expect((await saved()).containsKey('icon'), isFalse);
    },
  );
}
