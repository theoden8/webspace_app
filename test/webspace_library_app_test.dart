import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/site_grid_tile.dart';
import 'package:webspace/widgets/webspace_folder_tile.dart';
import 'helpers/real_app.dart';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));
  tearDown(ConnectivityService.reset);
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
      await pumpRealApp(tester, sites: [portal, other], webspaces: [work]);
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
      await pumpRealApp(tester, sites: [first, second], webspaces: [work]);
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
