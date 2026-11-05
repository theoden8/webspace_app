import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/widgets/backup_prompts.dart';

import 'helpers/localized.dart';

/// A backup of three sites, one with a user script, two webspaces, and an
/// app-wide proxy, exported at [at].
SettingsBackup _backup({required DateTime at, bool proxy = true}) =>
    SettingsBackup(
      version: 1,
      sites: [
        {'initUrl': 'https://a.example'},
        {
          'initUrl': 'https://b.example',
          'userScripts': [
            {'name': 'x', 'source': 'void 0;'},
          ],
        },
        {'initUrl': 'https://c.example'},
      ],
      webspaces: [
        {'name': 'Work'},
        {'name': 'Home'},
      ],
      themeMode: 0,
      globalPrefs: {
        if (proxy)
          AppPref.globalOutboundProxy.key: jsonEncode({
            'type': ProxyType.SOCKS5.index,
            'address': '10.0.0.5:1080',
          }),
      },
      exportedAt: at,
    );

/// The import confirmation over a page, and what it answered once tapped.
Future<List<bool>> _confirm(WidgetTester tester,
    {required SettingsBackup backup}) async {
  final answers = <bool>[];
  await pumpLocalized(
    tester,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async =>
            answers.add(await DialogBackupPrompts(context).confirmImport(backup)),
        child: const Text('import'),
      ),
    ),
  );
  await tester.tap(find.text('import'));
  await tester.pumpAndSettle();
  return answers;
}

void main() {
  testWidgets(
      'BACKUP-006: the import dialog names the counts, the export time, the '
      'incoming proxy and scripts, and the session note', (tester) async {
    final at = DateTime(2026, 1, 15, 9, 30);
    final answers = await _confirm(tester, backup: _backup(at: at));

    expect(find.text('Import 3 site(s) and 2 webspace(s)?'), findsOneWidget);
    expect(find.text('Exported: ${at.toString().split('.')[0]}'), findsOneWidget);
    expect(find.textContaining('10.0.0.5:1080'), findsOneWidget);
    expect(find.textContaining('installs 1 user script'), findsOneWidget);
    expect(find.textContaining('login sessions will be preserved'),
        findsOneWidget);

    await tester.tap(find.text('Import').last);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('BACKUP-006: without a proxy the dialog names none; Cancel declines',
      (tester) async {
    final answers =
        await _confirm(tester, backup: _backup(at: DateTime(2026), proxy: false));
    expect(find.textContaining('app-wide outbound proxy'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });
}
