import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/widgets/backup_prompts.dart';

import 'helpers/localized.dart';

// BACKUP-015: an import switches every script off (BACKUP-011) and holds
// the ones the backup ran, so the user can turn them back on as they were.

UserScriptConfig _script(String id, {bool enabled = true}) => UserScriptConfig(
  id: UserScriptId(id),
  name: 'script $id',
  source: '/* $id */',
  enabled: enabled,
);

/// Two sites as a device had them: A runs its own `s1` (its `s2` is off)
/// and the global `g1`; B runs `g1` and names a global the library lost.
/// `g2` is in the library but no site uses it.
SettingsImportPlan _planOfDevice() {
  final a = WebViewModel(
    initUrl: 'https://a.example',
    name: 'Site A',
    userScripts: [_script('s1'), _script('s2', enabled: false)],
    enabledGlobalScriptIds: {UserScriptId('g1')},
  );
  final b = WebViewModel(
    initUrl: 'https://b.example',
    name: 'Site B',
    enabledGlobalScriptIds: {UserScriptId('g1'), UserScriptId('gone')},
  );
  final backup = SettingsBackupService.createBackup(
    webViewModels: [a, b],
    webspaces: [Webspace.all()],
    themeMode: 0,
    globalUserScripts: [_script('g1').toJson(), _script('g2').toJson()],
  );
  return planSettingsImport(
    SettingsBackupService.importFromJson(
      SettingsBackupService.exportToJson(backup),
    )!,
  );
}

/// The ids of the scripts [site] injects.
Set<String> _running(WebViewModel site, {required SettingsImportPlan plan}) => {
  for (final s in site.combineUserScripts(plan.globalUserScripts!))
    if (s.enabled) s.id,
};

void main() {
  group('planSettingsImport holds what the backup ran', () {
    test(
      'installed global scripts get fresh ids and keep reviewed opt-ins',
      () {
        final plan = _planOfDevice();
        final originalId = plan.globalUserScripts!.first.id;
        final archived = WebViewModel(
          initUrl: 'https://archived.example',
          enabledGlobalScriptIds: {originalId},
        );
        final local = remintImportedGlobalScripts(
          plan.globalUserScripts!,
          held: plan.heldScripts,
        );
        expect(local.scripts.first.id, isNot(originalId));
        expect(archived.combineUserScripts(local.scripts), isEmpty);
        expect(
          local.held.whereType<HeldGlobalScript>().single.script,
          same(local.scripts.first),
        );
        for (final held in heldScriptsForSites(
          local.held,
          siteIds: {plan.sites.first.siteId},
          includeGlobalScripts: true,
        )) {
          held.release();
        }
        expect(
          plan.sites.first
              .combineUserScripts(local.scripts)
              .where((script) => script.enabled)
              .map((script) => script.id),
          contains(local.scripts.first.id),
        );
        expect(plan.sites.last.combineUserScripts(local.scripts), isEmpty);
      },
    );

    test('replacing the global library clears retained sites opt-ins', () {
      final retained = WebViewModel(
        initUrl: 'https://retained.example',
        enabledGlobalScriptIds: {UserScriptId('same-id')},
      );
      final alreadyOff = WebViewModel(initUrl: 'https://off.example');
      final replacement = _script('same-id');
      expect(retained.combineUserScripts([replacement]), hasLength(1));
      expect(clearRetainedGlobalScriptOptIns([retained, alreadyOff]), [
        retained,
      ]);
      expect(retained.enabledGlobalScriptIds, isEmpty);
      expect(retained.combineUserScripts([replacement]), isEmpty);
      expect(alreadyOff.enabledGlobalScriptIds, isEmpty);
    });

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

    test('releasing scripts for one site leaves the other site off', () {
      final plan = _planOfDevice();
      final [a, b] = plan.sites;
      final selected = heldScriptsForSites(
        plan.heldScripts,
        siteIds: {a.siteId},
        includeGlobalScripts: true,
      );
      for (final script in selected) {
        script.release();
      }
      expect(_running(a, plan: plan), {'g1', 's1'});
      expect(_running(b, plan: plan), isEmpty);
      expect(selected.whereType<HeldGlobalScript>().single.sites, [a]);
    });

    test('omitted global scripts stay off even on a selected site', () {
      final plan = _planOfDevice();
      final [a, b] = plan.sites;
      final selected = heldScriptsForSites(
        plan.heldScripts,
        siteIds: {a.siteId},
        includeGlobalScripts: false,
      );
      for (final script in selected) {
        script.release();
      }
      expect(_running(a, plan: plan), {'s1'});
      expect(_running(b, plan: plan), isEmpty);
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
    Future<Future<bool>> open(
      WidgetTester tester, {
      required List<HeldScript> held,
    }) async {
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
