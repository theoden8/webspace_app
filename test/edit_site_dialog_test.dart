import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/edit_site_dialog.dart';

import 'helpers/fake_outbound.dart';

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

Future<SiteEdit? Function()> _open(
  WidgetTester tester, {
  required WebViewModel site,
  List<Webspace> spaces = const [],
}) async {
  SiteEdit? result;
  var closed = false;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // The page's Scaffold, for the toast a title refresh shows.
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showEditSiteDialog(
                context,
                site: site,
                spaces: spaces,
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () {
    expect(closed, isTrue, reason: 'the dialog must have closed');
    return result;
  };
}

void main() {
  // A custom icon keeps the preview off the favicon fetch path.
  WebViewModel site() => WebViewModel(
    initUrl: 'https://example.com',
    name: 'Example',
    customIconPng: _png(),
  );

  testWidgets(
    'Save hands back the trimmed name and a schemed URL, icon untouched',
    (tester) async {
      final result = await _open(tester, site: site());
      await tester.enterText(
        find.widgetWithText(TextField, 'Site Name'),
        '  Renamed  ',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'URL'),
        ' example.org/path ',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final edit = result();
      expect(edit, isNotNull);
      expect(edit!.name, 'Renamed');
      expect(edit.url, 'https://example.org/path');
      expect(
        edit.icon,
        isNull,
        reason: 'an icon the user did not touch is not an edit',
      );
      expect(edit.spaces, isNull, reason: 'no webspaces were offered');
      expect(find.byType(FilterChip), findsNothing);
    },
  );

  testWidgets(
    'the webspaces offered start as the site is and Save hands back the choice (EDIT-011)',
    (tester) async {
      final edited = site();
      final work = Webspace(name: 'Work', siteIds: [edited.siteId]);
      final home = Webspace(name: 'Home');
      final result = await _open(tester, site: edited, spaces: [work, home]);
      bool chosen(String name) => tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, name))
          .selected;
      expect(chosen('Work'), isTrue);
      expect(chosen('Home'), isFalse);
      await tester.tap(find.widgetWithText(FilterChip, 'Work'));
      await tester.tap(find.widgetWithText(FilterChip, 'Home'));
      await tester.pump();
      expect(chosen('Work'), isFalse);
      expect(chosen('Home'), isTrue);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result()!.spaces, {home.id});
      expect(work.siteIds, [edited.siteId], reason: 'the dialog only answers');
    },
  );

  testWidgets('resetting the icon hands back an icon edit with no bytes', (
    tester,
  ) async {
    final result = await _open(tester, site: site());
    await tester.tap(find.byIcon(Icons.restart_alt));
    await tester.pump();
    expect(find.byIcon(Icons.restart_alt), findsNothing);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final edit = result();
    expect(edit!.icon, isNotNull);
    expect(edit.icon!.png, isNull);
  });

  testWidgets('Cancel hands back nothing', (tester) async {
    final result = await _open(tester, site: site());
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result(), isNull);
  });

  // The icon refresh the drawer once had lives here now: it drops the cached
  // icon so the preview fetches it again, and fills in the page's title.
  testWidgets('Refresh Title & Icon drops the cached icon (ICON-008)',
      (tester) async {
    outboundHttp = FakeOutbound(responder: (_) => http.Response(
        '<html><head><title>Fetched Title</title></head></html>', 200));
    addTearDown(resetOutboundHttp);
    addTearDown(clearFaviconCache);
    final plain = WebViewModel(initUrl: 'https://example.com', name: 'Example');
    await tester.runAsync(
        () => getFaviconUrlStream(plain.initUrl, proxy: OutboundProxy.app).drain<void>());
    final dropped = <String>[];
    final sub = faviconInvalidations.listen(dropped.add);
    addTearDown(sub.cancel);

    await _open(tester, site: plain);
    await tester.tap(find.text('Refresh Title & Icon'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(dropped, contains(plain.initUrl));
    expect(find.widgetWithText(TextField, 'Fetched Title'), findsOneWidget);
  });
}
