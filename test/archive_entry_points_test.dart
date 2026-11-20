import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/app_backup.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_list_menu.dart';

import 'helpers/archive_harness.dart';
import 'helpers/localized.dart';

/// ARCH-008. Archives are opened from Backup and archives by their
/// passphrase, a passphrase that names none says so and makes none, a site's
/// menu offers to close its archive only when it is in one, and Close all
/// archives shows only while one is open in this process.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A harness whose one archive holds a site and is closed again.
  Future<ArchiveHarness> closedArchive() async {
    final h = ArchiveHarness();
    final site = WebViewModel(
      siteId: SiteId('notes'),
      initUrl: 'https://notes.example',
    );
    h.load([site]);
    await h.archives.moveIn(site);
    expect(await h.archives.closeAll(), isTrue);
    expect(h.archives.anyOpen, isFalse);
    return h;
  }

  Future<void> showBackup(
    WidgetTester tester, {
    required ArchiveHarness h,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        AppBackupScreen(archives: h.archives, onOpenSite: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openArchives(WidgetTester tester) async {
    await tester.tap(find.text('Open archives'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  String said(WidgetTester tester, {required ArchiveHarness h}) => h.toasts
      .last(AppLocalizations.of(tester.element(find.byType(AppBackupScreen))));

  testWidgets('its passphrase opens an archive from Backup and archives '
      '(ARCH-008)', (tester) async {
    final h = await tester.runAsync(closedArchive);
    await showBackup(tester, h: h!);
    expect(find.text('Archive 1'), findsNothing);
    await openArchives(tester);
    expect(h.archives.anyOpen, isTrue);
    expect(find.text('Archive 1'), findsOneWidget);
    await tester.tap(find.text('Archive 1'));
    await tester.pumpAndSettle();
    expect(find.text('https://notes.example'), findsOneWidget);
  });

  testWidgets('a passphrase that names no archive says so and makes none '
      '(ARCH-008)', (tester) async {
    final h = await tester.runAsync(closedArchive);
    final slots = await tester.runAsync(() => h!.slots.readAll());
    h!.passphraseAnswer = 'not the passphrase';
    await showBackup(tester, h: h);
    await openArchives(tester);
    expect(h.archives.anyOpen, isFalse);
    expect(said(tester, h: h), 'No matching archive');
    expect(
      await tester.runAsync(() => h.slots.readAll()),
      slots,
      reason: 'no archive was created',
    );
  });

  testWidgets('Close all archives shows only while one is open (ARCH-008)', (
    tester,
  ) async {
    final h = await tester.runAsync(closedArchive);
    await showBackup(tester, h: h!);
    expect(find.text('Close all archives'), findsNothing);
    await openArchives(tester);
    expect(find.text('Close all archives'), findsOneWidget);
    await tester.tap(find.text('Close all archives'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(h.archives.anyOpen, isFalse);
    expect(find.text('Close all archives'), findsNothing);
  });

  for (final archived in [true, false]) {
    testWidgets('a site\'s menu offers Close archive only when the site is in '
        'one, here ${archived ? 'archived' : 'not'} (ARCH-008)', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSiteListMenu(
              context,
              position: Offset.zero,
              canMoveUp: false,
              canMoveDown: false,
              archived: archived,
              canArchive: true,
            ),
            child: const Text('menu'),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();
      expect(
        find.text('Close archive'),
        archived ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Move to archive'),
        archived ? findsNothing : findsOneWidget,
      );
    });
  }
}
