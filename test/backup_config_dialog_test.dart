import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/backup_controller.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/backup_prompts.dart';

import 'helpers/localized.dart';

void main() {
  testWidgets('export checklist controls app scope', (tester) async {
    late BuildContext context;
    await pumpLocalized(
      tester,
      home: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    final site = WebViewModel(initUrl: 'https://example.com', name: 'Example');
    final answer = DialogBackupPrompts(context).configureExport([site], null);
    await tester.pumpAndSettle();
    expect(find.text('Example'), findsNothing);
    await tester.tap(find.text('Sites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Site cookies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create backup').last);
    await tester.pumpAndSettle();
    final choices = await answer;
    expect(choices, isA<BackupExportChoices>());
    expect(choices!.siteIds, contains(site.siteId));
    expect(choices.siteCookieIds, isEmpty);
    expect(choices.appSettings, isFalse);
  });

  testWidgets('restore review leaves scripts off unless selected', (
    tester,
  ) async {
    late BuildContext context;
    await pumpLocalized(
      tester,
      home: Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    final backup = SettingsBackup(
      version: 1,
      sites: [
        {
          'name': 'Example',
          'userScripts': [
            {'name': 'Sample'},
          ],
        },
      ],
      webspaces: const [],
      themeMode: 0,
      exportedAt: DateTime(2026),
    );
    final answer = DialogBackupPrompts(context).reviewImport(backup);
    await tester.pumpAndSettle();
    expect(
      find.text('Turn previously enabled user scripts back on'),
      findsOneWidget,
    );
    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();
    expect((await answer)!.turnOnScripts, isFalse);
  });
}
