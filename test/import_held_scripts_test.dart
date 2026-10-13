import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/backup_prompts.dart';

import 'helpers/localized.dart';

// BACKUP-015: an import switches every script off (BACKUP-011) and holds
// the ones the backup ran, so the user can turn them back on as they were.

UserScriptConfig _script(String id, {bool enabled = true}) => UserScriptConfig(
    id: id, name: 'script $id', source: '/* $id */', enabled: enabled);

/// Two sites as a device had them: A runs its own `s1` (its `s2` is off)
/// and the global `g1`; B runs `g1` and names a global the library lost.
/// `g2` is in the library but no site uses it.
SettingsImportPlan _planOfDevice() {
  final a = WebViewModel(
    initUrl: 'https://a.example',
    name: 'Site A',
    userScripts: [_script('s1'), _script('s2', enabled: false)],
    enabledGlobalScriptIds: {'g1'},
  );
  final b = WebViewModel(
    initUrl: 'https://b.example',
    name: 'Site B',
    enabledGlobalScriptIds: {'g1', 'gone'},
  );
  final backup = SettingsBackupService.createBackup(
    webViewModels: [a, b],
    webspaces: [Webspace.all()],
    themeMode: 0,
    globalUserScripts: [_script('g1').toJson(), _script('g2').toJson()],
  );
  return planSettingsImport(SettingsBackupService.importFromJson(
      SettingsBackupService.exportToJson(backup))!);
}

/// The ids of the scripts [site] injects.
Set<String> _running(WebViewModel site, {required SettingsImportPlan plan}) =>
    {
      for (final s in site.combineUserScripts(plan.globalUserScripts!))
        if (s.enabled) s.id,
    };

void main() {
  group('planSettingsImport holds what the backup ran', () {
    test('nothing runs until a held script is released', () {
      final plan = _planOfDevice();
      for (final site in plan.sites) {
        expect(_running(site, plan: plan), isEmpty, reason: site.name);
      }
    });

    test('a held script per running script, with the sites it ran on', () {
      final plan = _planOfDevice();
      final [a, b] = plan.sites;
      final held = plan.heldScripts;
      expect(held, hasLength(2));
      final global = held.whereType<HeldGlobalScript>().single;
      expect(global.script.id, 'g1');
      expect(global.sites, [a, b]);
      final own = held.whereType<HeldSiteScript>().single;
      expect(own.script.id, 's1');
      expect(own.site, same(a));
    });

    test('releasing every held script restores what each site ran', () {
      final plan = _planOfDevice();
      for (final held in plan.heldScripts) {
        held.release();
      }
      final [a, b] = plan.sites;
      expect(_running(a, plan: plan), {'g1', 's1'});
      expect(_running(b, plan: plan), {'g1'});
      expect(a.userScripts.singleWhere((s) => s.id == 's2').enabled, isFalse);
    });

    test('a backup that ran no script holds none', () {
      final backup = SettingsBackupService.createBackup(
        webViewModels: [
          WebViewModel(
            initUrl: 'https://a.example',
            userScripts: [_script('s1', enabled: false)],
          ),
        ],
        webspaces: [Webspace.all()],
        themeMode: 0,
        globalUserScripts: [_script('g1').toJson()],
      );
      expect(planSettingsImport(backup).heldScripts, isEmpty);
    });
  });

  group('DialogBackupPrompts.confirmRestoreScripts', () {
    /// Opens the prompt over a bare page; the future completes with the
    /// answer.
    Future<Future<bool>> open(WidgetTester tester,
        {required List<HeldScript> held}) async {
      late BuildContext context;
      await pumpLocalized(tester, home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      }));
      final answer = DialogBackupPrompts(context).confirmRestoreScripts(held);
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('names each script and the sites it ran on', (tester) async {
      await open(tester, held: _planOfDevice().heldScripts);
      expect(find.text('script g1'), findsOneWidget);
      expect(find.text('Runs on Site A, Site B'), findsOneWidget);
      expect(find.text('script s1'), findsOneWidget);
      expect(find.text('Runs on Site A'), findsOneWidget);
      expect(find.text('script s2'), findsNothing);
    });

    testWidgets('turn on is a yes', (tester) async {
      final answer = await open(tester, held: _planOfDevice().heldScripts);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
    });

    testWidgets('leave off is a no', (tester) async {
      final answer = await open(tester, held: _planOfDevice().heldScripts);
      await tester.tap(find.text('Leave off'));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });
  });
}
