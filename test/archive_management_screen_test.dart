import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/app_backup.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/archive_harness.dart';
import 'helpers/localized.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('open archive lists its site and can close that archive', (
    tester,
  ) async {
    final h = ArchiveHarness();
    final site = WebViewModel(
      siteId: SiteId('notes'),
      initUrl: 'https://notes.example',
    );
    h.load([site]);
    await h.archives.moveIn(site);

    await tester.pumpWidget(
      localizedApp(
        AppBackupScreen(archives: h.archives, onOpenSite: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open archives'), findsOneWidget);
    expect(find.text('Archive 1'), findsOneWidget);

    await tester.tap(find.text('Archive 1'));
    await tester.pumpAndSettle();
    expect(find.text('https://notes.example'), findsOneWidget);
    await tester.tap(find.text('Close archive'));
    await tester.pumpAndSettle();

    expect(h.archives.anyOpen, isFalse);
    expect(find.text('Archive 1'), findsNothing);
  });

  testWidgets('remove action keeps the listed site', (tester) async {
    final h = ArchiveHarness();
    final site = WebViewModel(
      siteId: SiteId('notes'),
      initUrl: 'https://notes.example',
    );
    h.load([site]);
    await h.archives.moveIn(site);
    await tester.pumpWidget(
      localizedApp(AppBackupScreen(archives: h.archives)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Archive 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove archive and keep sites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(site.isArchiveTier, isFalse);
    expect(h.archives.anyOpen, isFalse);
    expect(find.text('Archive 1'), findsNothing);
  });
}
