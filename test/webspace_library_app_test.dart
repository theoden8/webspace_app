import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/launcher_item_size.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/tabs_sheet.dart';
import 'package:webspace/widgets/webspace_group_tile.dart';
import 'helpers/real_app.dart';
import 'helpers/group_tile.dart';

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
      await tester.tap(find.byType(BackButton));
      await settleRealApp(tester);
      await tester.longPress(find.text('Work'));
      await settleRealApp(tester);
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await settleRealApp(tester);
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
    expect(find.byType(BackButton), findsNothing);
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
    'reordering sites keeps the group open; a swipe returns to groups',
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
      final alphaTile = find.byKey(ValueKey(appSite('Alpha').siteId));
      final betaTile = find.byKey(ValueKey(appSite('Beta').siteId));
      final drag = await tester.startGesture(tester.getCenter(alphaTile));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.moveTo(tester.getCenter(betaTile));
      await tester.pump();
      await drag.up();
      await settleRealApp(tester);
      expect(find.byType(BackButton), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs
          .getStringList('webspaces')!
          .map(
            (raw) => Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          )
          .singleWhere((group) => group.id == work.id);
      expect(saved.siteIds, [beta.siteId, alpha.siteId]);
      await tester.flingFrom(
        tester.getCenter(betaTile),
        const Offset(180, 0),
        1000,
      );
      await settleRealApp(tester);
      expect(find.byType(WebspaceGroupTile), findsNWidgets(2));
      expect(find.byType(SiteGridTile), findsNothing);
      expect(prefs.getString('selectedWebspaceId'), work.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'item sizes persist independently without an edit mode (WEBSPACE-014)',
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
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      await tester.longPress(find.text('Work'));
      await settleRealApp(tester);
      await tester.tap(find.text('Item size'));
      await settleRealApp(tester);
      await tester.tap(find.text('Large'));
      await settleRealApp(tester);
      final prefs = await SharedPreferences.getInstance();
      final savedGroup = prefs
          .getStringList('webspaces')!
          .map(
            (raw) => Webspace.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          )
          .singleWhere((value) => value.id == work.id);
      expect(savedGroup.launcherSize, LauncherItemSize.large);
      await openWebspace(tester, name: 'Work');
      final alphaTile = find.ancestor(
        of: find.text('Alpha'),
        matching: find.byType(SiteGridTile),
      );
      await tester.tap(
        find.descendant(of: alphaTile, matching: find.byIcon(Icons.more_vert)),
      );
      await settleRealApp(tester);
      await tester.tap(find.text('Item size'));
      await settleRealApp(tester);
      await tester.tap(find.text('Small'));
      await settleRealApp(tester);
      expect(appSite('Alpha').launcherSize, LauncherItemSize.small);
      expect(appSite('Beta').launcherSize, LauncherItemSize.medium);
      final savedSite = prefs
          .getStringList('webViewModels')!
          .map(
            (raw) => WebViewModel.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
              stateSetterF: null,
            ),
          )
          .singleWhere((value) => value.name == 'Alpha');
      expect(savedSite.launcherSize, LauncherItemSize.small);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Sites opens a nested tab through the app tab controller', (
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
    await tester.tap(find.text('Sites'));
    await settleRealApp(tester);
    await tester.tap(find.text('Deep article'));
    await settleRealApp(tester);
    expect(appSite('Alpha').activeTabId, child.id);
    expect(find.byType(WebspaceLibrary), findsNothing);
    await tester.tap(find.byTooltip('Back to Webspaces'));
    await settleRealApp(tester);
    expect(find.byType(TabsSheet), findsOneWidget);
    expect(find.text('Deep article'), findsOneWidget);
    await tester.tap(find.text('Deep article'));
    await settleRealApp(tester);
    expect(appSite('Alpha').activeTabId, child.id);
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
    'selecting a folder persists its scope and opens sites without a drawer (WEBSPACE-002, WEBSPACE-004, WEBSPACE-008)',
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
      await tester.tap(find.byType(BackButton));
      await settleRealApp(tester);
      expect(find.byType(WebspaceGroupTile), findsNWidgets(2));
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
}
