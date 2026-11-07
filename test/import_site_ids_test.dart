import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings_import_engine.dart';

// Two site records that share an id share one container: one cookie jar, one
// storage partition (policy.md R8). Within one backup the planner keeps the
// first record's id and mints a fresh one for each later copy. Across the app
// tier and open archives nothing checks it yet (policy_debt.tsv).
SettingsBackup _backup(List<Map<String, dynamic>> sites) => SettingsBackup(
      version: 1,
      sites: sites,
      webspaces: const [],
      themeMode: 0,
      exportedAt: DateTime(2026),
    );

void main() {
  test('a backup whose sites share an id imports them with distinct ids', () {
    final plan = planSettingsImport(_backup([
      {'siteId': 'dup', 'initUrl': 'https://a.example/'},
      {'siteId': 'dup', 'initUrl': 'https://b.example/'},
      {'siteId': 'dup', 'initUrl': 'https://c.example/'},
    ]));
    final ids = [for (final s in plan.sites) s.siteId];
    expect(ids.toSet(), hasLength(3), reason: 'every record gets its own container');
    expect(plan.sites.first.siteId, 'dup', reason: 'the first record keeps its id');
    expect(plan.sites.first.initUrl, 'https://a.example/');
  });

  test('distinct ids pass through unchanged', () {
    final plan = planSettingsImport(_backup([
      {'siteId': 'one', 'initUrl': 'https://a.example/'},
      {'siteId': 'two', 'initUrl': 'https://b.example/'},
    ]));
    expect([for (final s in plan.sites) s.siteId], ['one', 'two']);
  });
}
