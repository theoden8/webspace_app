// Runs inside a release's own checkout (see generate.sh), never at test time.
// Everything here must compile against every release since v0.0.4, so it only
// touches APIs that exist in all of them; anything newer goes through the
// feature files next to it, which generate.sh swaps for their `features_off/`
// twins when the release predates the feature.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'features/links.dart';
import 'features/qr.dart';
import 'features/registry.dart';
import 'features/scripts.dart';
import 'features/theme.dart';

const _outDir = String.fromEnvironment('BACKUP_COMPAT_OUT');
const _supersetPath = String.fromEnvironment('BACKUP_COMPAT_SUPERSET');

/// Named parameters of this release's `SettingsBackupService.createBackup`,
/// read from its source so one generator can call every signature it had.
Set<String> _createBackupParams() {
  final src = File('lib/services/settings_backup.dart').readAsStringSync();
  final start = src.indexOf('static SettingsBackup createBackup({');
  if (start < 0) throw StateError('createBackup not found');
  final end = src.indexOf('})', start);
  final block = src.substring(start, end);
  return {
    for (final m in RegExp(r'(\w+),\s*$', multiLine: true).allMatches(block))
      m.group(1)!,
  };
}

Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from(v as Map);

String _export({
  required Map<String, dynamic> superset,
  required List<WebViewModel> models,
  required List<Webspace> webspaces,
  required int themeIndex,
  required Map<String, Object?>? registryPrefs,
  required Map<String, dynamic> flatPrefs,
  required bool withExtras,
}) {
  final params = _createBackupParams();
  final hasRegistry = params.contains('globalPrefs') && registryPrefs != null;
  final values = <String, Object?>{
    'webViewModels': models,
    'webspaces': webspaces,
    'themeMode': themeIndex,
    'selectedWebspaceId': withExtras ? superset['selectedWebspaceId'] : null,
    'currentIndex': withExtras ? superset['currentIndex'] : null,
    if (hasRegistry) 'globalPrefs': registryPrefs,
    // Before the registry, main.dart passed these flat. Once it existed it
    // passed only `globalPrefs`, so the flat ones stay unset there.
    'showUrlBar': hasRegistry ? null : flatPrefs['showUrlBar'] ?? false,
    'showTabStrip': hasRegistry ? null : flatPrefs['showTabStrip'],
    'showStatsBanner': hasRegistry ? null : flatPrefs['showStatsBanner'],
    'suggestedSites': withExtras
        ? <Map<String, dynamic>>[
            for (final e in superset['suggestedSites'] as List) _map(e)
          ]
        : null,
    'globalUserScripts': withExtras
        ? shimGlobalScripts(superset['globalUserScripts'] as List)
        : null,
    'dnsBlockLevel': withExtras ? superset['dnsBlockLevel'] : null,
    'contentBlockerLists': withExtras
        ? <Map<String, dynamic>>[
            for (final e in superset['contentBlockerLists'] as List) _map(e)
          ]
        : null,
    'extraSections': null,
  };
  final unknown = params.difference(values.keys.toSet());
  if (unknown.isNotEmpty) {
    throw StateError('createBackup has params the generator does not '
        'know: $unknown. Teach generator_test.dart what main.dart passed.');
  }
  final named = <Symbol, Object?>{
    for (final p in params)
      if (values[p] != null) Symbol(p): values[p],
  };
  final backup = Function.apply(SettingsBackupService.createBackup, [], named)
      as SettingsBackup;
  return SettingsBackupService.exportToJson(backup);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('write backup compat fixtures', () async {
    if (_outDir.isEmpty || _supersetPath.isEmpty) {
      fail('run through tool/backup_compat/generate.sh');
    }
    final superset = _map(jsonDecode(File(_supersetPath).readAsStringSync()));
    final out = Directory(_outDir)..createSync(recursive: true);
    void write(String name, String body) =>
        File('${out.path}/$name').writeAsStringSync(body);

    final supersetPrefs = _map(superset['globalPrefs']);
    // What this release kept in SharedPreferences for the app-wide proxy:
    // its own `UserProxySettings.toJson`, password included where it did.
    final prefValues = <String, Object>{
      for (final e in supersetPrefs.entries)
        if (e.key == 'globalOutboundProxy')
          e.key: jsonEncode(UserProxySettings.fromJson(_map(e.value)).toJson())
        else if (e.value is List)
          e.key: <String>[for (final v in e.value as List) v as String]
        else
          e.key: e.value as Object,
    };

    final theme = _map(superset['theme']);
    final allWebspace = Webspace.fromJson({
      'id': kAllWebspaceId,
      'name': 'All',
      'siteIndices': <int>[],
      'siteIds': <String>[],
    });

    final models = <WebViewModel>[
      for (final s in superset['sites'] as List)
        WebViewModel.fromJson(_map(jsonDecode(jsonEncode(s))), null),
    ];
    final webspaces = <Webspace>[
      allWebspace,
      for (final w in superset['webspaces'] as List)
        Webspace.fromJson(_map(jsonDecode(jsonEncode(w)))),
    ];
    write(
      'backup_maximal.json',
      _export(
        superset: superset,
        models: models,
        webspaces: webspaces,
        themeIndex: shimThemeIndex(
            theme['themeMode'] as String, theme['accentColor'] as String),
        registryPrefs: await shimReadRegistry(prefValues),
        flatPrefs: supersetPrefs,
        withExtras: true,
      ),
    );

    write(
      'backup_minimal.json',
      _export(
        superset: superset,
        models: [WebViewModel(initUrl: 'https://minimal.example/')],
        webspaces: [allWebspace],
        themeIndex: 0,
        registryPrefs: await shimReadRegistry(<String, Object>{}),
        flatPrefs: const {},
        withExtras: false,
      ),
    );

    final qr = shimQr(models.first.toJson());
    if (qr != null) write('qr_maximal.txt', '$qr\n');

    if (shimHasLinks) {
      final links = <String, String?>{
        for (final u in superset['links'] as List)
          u as String: shimParseLink(u),
      };
      write('links.json',
          '${const JsonEncoder.withIndent('  ').convert(links)}\n');
    }
  });
}
