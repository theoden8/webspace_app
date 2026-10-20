import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/webspace_library.dart';
import 'package:webspace/screens/webspaces_list.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/webspace_folder_tile.dart';
import 'helpers/real_app.dart';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));
  tearDown(ConnectivityService.reset);
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
      expect(find.byType(WebspaceFolderTile), findsNWidgets(2));
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
          .widgetList<WebspaceFolderTile>(find.byType(WebspaceFolderTile))
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
