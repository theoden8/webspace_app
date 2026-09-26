import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' show AccentColor, AppThemeSettings;
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/trusted_hosts_service.dart' show kTrustedHostsKey;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// BACKUP-012 and BACKUP-014: what an older release wrote still loads, without
/// throwing and without losing a setting.
///
/// `test/fixtures/backup_compat/<tag>/` is what each release really wrote:
/// `tool/backup_compat/generate.sh` ran the release's own serializers over
/// `tool/backup_compat/superset.json`. Every key a release wrote must still be
/// read, and its value must come back; a key the release did not know is
/// absent from its fixture and must import as a fresh site's default.
///
/// The import's security rules (BACKUP-011, PWD-005, BACKUP-010) hold for any
/// input whoever wrote it, so they are tested once, against hostile input,
/// in the last groups rather than per release.

const _fixtureRoot = 'test/fixtures/backup_compat';

/// Releases whose export wrote `ThemeMode.index` instead of
/// `themeMode * 10 + accent`. A fact about those releases, not a heuristic,
/// so it checks the heuristic in `normalizeBackupThemeIndex`.
const _preAccentReleases = {'v0.0.4', 'v0.0.5'};

const _needles = [
  'site-proxy-password-needle-a41c',
  'global-proxy-password-needle-9e2d',
  'tls-pin-needle-c0de',
  'secure-cookie-needle-5d1e',
  'incognito-cookie-needle-77b0',
];

final Map<String, dynamic> _superset = jsonDecode(
    File('tool/backup_compat/superset.json').readAsStringSync());

List<Map<String, dynamic>> get _supersetSites => [
      for (final s in _superset['sites'] as List) s as Map<String, dynamic>,
    ];

List<int> _versionKey(String tag) =>
    tag.substring(1).split('.').map(int.parse).toList();

int _compareTags(String a, String b) {
  final x = _versionKey(a), y = _versionKey(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

List<String> _releaseTags() => [
      for (final d in Directory(_fixtureRoot).listSync().whereType<Directory>())
        if (d.path.split(Platform.pathSeparator).last case final name
            when RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(name))
          name,
    ]..sort(_compareTags);

String _read(String tag, String name) =>
    File('$_fixtureRoot/$tag/$name').readAsStringSync();

bool _has(String tag, String name) =>
    File('$_fixtureRoot/$tag/$name').existsSync();

/// A fresh site's serialised defaults: what a key the release never wrote
/// must come back as.
Map<String, dynamic> _freshSiteJson(String initUrl) {
  final fresh = [WebViewModel(initUrl: initUrl)];
  sanitizeImportedSites(fresh);
  return fresh.single.toJson();
}

/// The values an import deliberately does not keep (BACKUP-011: real-device
/// grants and the global-script opt-in reset on every import, whoever wrote
/// the file). Everything else must survive as written.
Object? _expectedImported(String key, Object? value) => switch (key) {
      'cameraMode' || 'microphoneMode' =>
        value == 'real' || value == 'ask' ? null : value,
      'locationMode' => value == 'live' ? 'off' : value,
      'notificationsEnabled' => false,
      'backgroundAudioEnabled' => null,
      'protectedContentAllowed' => value == true ? null : value,
      'enabledGlobalScriptIds' => null,
      'disabledFilterLists' => ([...value as List]..sort()),
      _ => value,
    };

/// A key a release wrote under a name HEAD no longer uses, and the name its
/// value lives under now. `fromJson` must read the old name and carry the
/// value over; add the pair here when you rename a persisted key.
const Map<String, String> _renamedKeys = {
  // Per-site `tabBarButtonOnRight` (never in a release) became
  // `tabBarButtonCorner`.
  // The per-site bool gained a third value (issue #629): `true` is the
  // browser mode.
  'externalLinksInBrowser': 'externalLinkMode',
};

/// A key a release wrote that HEAD deliberately stops reading, and why losing
/// it is intended. Anything else a release wrote must still be read.
const Map<String, String> _retiredKeys = {
  'trustedHosts': 'BACKUP-010: a TLS pin never rides a backup',
};

/// Keys checked by hand below rather than by the generic oracle.
const _specialKeys = {
  'siteId',
  'initUrl',
  'currentUrl',
  'pageTitle',
  'cookies',
  'proxySettings',
  'userScripts',
};

Set<String> _matches(String text, String pattern) =>
    {for (final m in RegExp(pattern).allMatches(text)) m.group(1)!};

String _region(String path, String from, String to) {
  final src = File(path).readAsStringSync();
  final start = src.indexOf(from);
  if (start < 0) throw StateError('no "$from" in $path');
  final end = src.indexOf(to, start + from.length);
  return src.substring(start, end < 0 ? src.length : end);
}

/// A key read out of a JSON map, in any of the spellings the parsers use.
const _readPattern =
    r"(?:\b(?:json|e|values)\[\s*'(\w+)'\s*\]|\b(?:field<[^>]*>|finite|text)\(\s*'(\w+)')";

Set<String> _readKeys(String text) => {
      for (final m in RegExp(_readPattern).allMatches(text))
        (m.group(1) ?? m.group(2))!,
    };

/// Every JSON key the backup, site, webspace and nested parsers read, taken
/// from their source so a rename that forgets the old name shows up.
final Set<String> _keysRead = {
  for (final f in const [
    'lib/web_view_model.dart',
    'lib/webspace_model.dart',
    'lib/services/settings_backup.dart',
    'lib/services/settings_import_engine.dart',
    'lib/services/domain_claim.dart',
    'lib/settings/proxy.dart',
    'lib/settings/user_script.dart',
    'lib/settings/virtual_visual_source.dart',
    'lib/settings/camera.dart',
    'lib/settings/microphone.dart',
    'lib/settings/screen_share.dart',
  ])
    ..._readKeys(File(f).readAsStringSync()),
  ..._readKeys(_region('lib/services/webview.dart', 'Cookie cookieFromJson(', ');\n')),
  ..._matches(
      _region('lib/services/settings_backup.dart', 'for (final key in const [', ']'),
      r"'(\w+)'"),
};

/// `globalPrefs` keys an import applies: the registry plus the old names
/// `resolveExportedAppPrefs` still reads.
final Set<String> _prefKeysRead = {
  ...kExportedAppPrefs.keys,
  ..._readKeys(File('lib/settings/app_prefs.dart').readAsStringSync()),
};

SettingsBackup _reexport(SettingsImportPlan plan) =>
    SettingsBackupService.createBackup(
      webViewModels: plan.sites,
      webspaces: plan.webspaces,
      themeMode: plan.themeStorageIndex,
      globalPrefs: plan.appPrefs,
      selectedWebspaceId: plan.selectedWebspaceId,
      currentIndex: plan.currentIndex,
      suggestedSites: plan.suggestedSites
          ?.map((s) => {'name': s.name, 'url': s.url, 'domain': s.domain})
          .toList(),
      globalUserScripts:
          plan.globalUserScripts?.map((s) => s.toJson()).toList(),
      dnsBlockLevel: plan.dnsBlockLevel,
      contentBlockerLists: plan.contentBlockerLists,
    );

String _withoutTimestamp(String exported) {
  final json = jsonDecode(exported) as Map<String, dynamic>..remove('exportedAt');
  return jsonEncode(json);
}

SettingsImportPlan _planFromJson(Object json) => planSettingsImport(
    SettingsBackupService.importFromJson(jsonEncode(json))!);

/// The security invariants every import holds, whatever wrote the file.
void _expectSanitised(SettingsImportPlan plan, {required String reason}) {
  final siteIds = <String>{};
  for (final site in plan.sites) {
    expect(sanitizedSiteId(site.siteId), isNotNull, reason: reason);
    expect(siteIds.add(site.siteId), isTrue,
        reason: '$reason: siteId ${site.siteId} shared by two sites');
    expect(site.proxySettings.password, isNull, reason: reason);
    expect(site.enabledGlobalScriptIds, isEmpty, reason: reason);
    expect(site.userScripts.where((s) => s.enabled), isEmpty, reason: reason);
    expect(site.cameraMode, isNot(CameraAccessMode.real), reason: reason);
    expect(site.microphoneMode, isNot(MicrophoneAccessMode.real),
        reason: reason);
    expect(site.locationMode, isNot(LocationMode.live), reason: reason);
    expect(site.notificationsEnabled, isFalse, reason: reason);
    expect(site.backgroundAudioEnabled, isFalse, reason: reason);
    expect(site.protectedContentAllowed, isNot(true), reason: reason);
  }
  expect(plan.globalUserScripts?.where((s) => s.enabled) ?? const [], isEmpty,
      reason: reason);
  expect(plan.appPrefs.containsKey(kTrustedHostsKey), isFalse, reason: reason);
  expect(
    (plan.appPrefs[kGlobalOutboundProxyKey] as String).contains('"password"'),
    isFalse,
    reason: reason,
  );
  expect(plan.appPrefs.keys.toSet(), kExportedAppPrefs.keys.toSet(),
      reason: reason);
  for (final e in kExportedAppPrefs.entries) {
    expect(plan.appPrefs[e.key].runtimeType, e.value.runtimeType,
        reason: '$reason: ${e.key} has the wrong type');
  }
  expect(
    () => AppThemeSettings.fromStorageIndex(plan.themeStorageIndex),
    returnsNormally,
    reason: reason,
  );
}

String? _parseLinkAtHead(String raw) {
  try {
    return LinkRoutingService.parseWebspaceUri(Uri.parse(raw))?.toString();
  } on FormatException {
    return '!throws';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tags = _releaseTags();

  test('fixtures exist for the releases', () {
    expect(tags, isNotEmpty);
    expect(tags.first, 'v0.0.4',
        reason: 'v0.0.4 is the first release with a backup format');
  });

  for (final tag in tags) {
    group(tag, () {
      final raw = _read(tag, 'backup_maximal.json');
      final backup = SettingsBackupService.importFromJson(raw);
      final plan = backup == null ? null : planSettingsImport(backup);

      test('maximal backup parses and plans', () {
        expect(backup, isNotNull, reason: 'importFromJson rejected it');
        expect(plan, isNotNull);
      });
      if (backup == null || plan == null) return;

      test('every key it wrote is still read', () {
        final unread = <String>[];
        void walk(Object? node, String at) {
          if (node is List) {
            for (var i = 0; i < node.length; i++) {
              walk(node[i], '$at[$i]');
            }
          } else if (node is Map) {
            for (final e in node.entries) {
              final key = e.key as String;
              final where = at.isEmpty ? key : '$at.$key';
              if (_retiredKeys.containsKey(key)) continue;
              if (at.endsWith('globalPrefs')) {
                if (!_prefKeysRead.contains(key)) unread.add(where);
                if (key == kGlobalOutboundProxyKey && e.value is String) {
                  walk(jsonDecode(e.value as String), where);
                }
                continue;
              }
              if (!_keysRead.contains(key) && !_renamedKeys.containsKey(key)) {
                unread.add(where);
              }
              walk(e.value, where);
            }
          }
        }

        walk(jsonDecode(raw), '');
        expect(unread, isEmpty,
            reason: '$tag wrote these and HEAD never reads them, so an import '
                'or upgrade from $tag drops them. Read the old name in '
                'fromJson (and add it to _renamedKeys), or list it in '
                '_retiredKeys with the reason.');
      });

      test('sites keep every field the release wrote', () {
        final supersetSites = _supersetSites;
        expect(plan.sites.length, supersetSites.length);
        for (var i = 0; i < supersetSites.length; i++) {
          final want = supersetSites[i];
          final written = backup.sites[i];
          final site = plan.sites[i];
          final got = site.toJson();
          final fresh = _freshSiteJson(want['initUrl'] as String);
          final where = '$tag site $i (${want['name']})';

          expect(site.name, want['name'], reason: where);
          expect(site.initUrl,
              migrateLegacyFileImportUrl(want['initUrl'] as String),
              reason: where);
          if (written.containsKey('siteId')) {
            expect(site.siteId, written['siteId'], reason: where);
          }

          final dropsNav = site.incognito || site.alwaysOpenHome;
          expect(got['currentUrl'],
              dropsNav ? isNull : migrateLegacyFileImportUrl(written['currentUrl'] as String),
              reason: '$where currentUrl');
          expect(got['pageTitle'], dropsNav ? isNull : written['pageTitle'],
              reason: '$where pageTitle');

          final writtenCookies = [
            for (final c in written['cookies'] as List) (c as Map)['name'],
          ];
          expect([for (final c in site.cookies) c.name],
              site.incognito ? isEmpty : writtenCookies,
              reason: '$where cookies');

          final proxy = want['proxySettings'] as Map<String, dynamic>;
          expect(site.proxySettings.type.index, proxy['type'], reason: where);
          expect(site.proxySettings.address, proxy['address'], reason: where);
          expect(site.proxySettings.username, proxy['username'], reason: where);
          expect(site.proxySettings.password, isNull, reason: where);

          if (written['userScripts'] is List) {
            final scripts = want['userScripts'] as List? ?? const [];
            expect(site.userScripts.length, scripts.length, reason: where);
            for (var j = 0; j < scripts.length; j++) {
              final s = scripts[j] as Map<String, dynamic>;
              final writtenScript =
                  (written['userScripts'] as List)[j] as Map<String, dynamic>;
              final restored = site.userScripts[j];
              // v0.1.6 to v0.2.0 wrote scripts without an id.
              expect(restored.id,
                  writtenScript['id'] ?? isNotEmpty, reason: '$where script id');
              expect(restored.source, s['source'], reason: where);
              expect(restored.enabled, isFalse, reason: where);
              expect(
                restored.bypassSitePolicy,
                writtenScript.containsKey('bypassSitePolicy')
                    ? s['bypassSitePolicy']
                    : false,
                reason: '$where bypassSitePolicy',
              );
            }
          } else {
            expect(site.userScripts, isEmpty, reason: where);
          }

          for (final key in want.keys) {
            if (_specialKeys.contains(key)) continue;
            final writtenAs = written.containsKey(key)
                ? key
                : [
                    for (final e in _renamedKeys.entries)
                      if (e.value == key && written.containsKey(e.key)) e.key,
                  ].firstOrNull;
            final expected = writtenAs != null
                ? _expectedImported(key, want[key])
                : fresh[key];
            expect(got[key], expected,
                reason: writtenAs != null
                    ? '$where: "$writtenAs" did not survive import as "$key"'
                    : '$where: "$key" is absent from $tag and must import '
                        'as a fresh site\'s default');
          }
        }
      });

      test('webspaces, selection and theme', () {
        expect(plan.webspaces.first.isAll, isTrue);
        final byName = {
          for (final ws in plan.webspaces.skip(1))
            ws.name: [
              for (final id in ws.siteIds)
                plan.sites.firstWhere((s) => s.siteId == id).name,
            ],
        };
        expect(byName, {
          'Work': ['Mail', 'Dashboard', 'notes'],
          'Private': ['Private'],
        });
        expect(plan.webspaces.skip(1).map((ws) => ws.id),
            ['ws-compat-work', 'ws-compat-private']);
        expect(plan.selectedWebspaceId, 'ws-compat-work');
        expect(plan.currentIndex, 2);

        final theme = AppThemeSettings.fromStorageIndex(plan.themeStorageIndex);
        expect(theme.themeMode, ThemeMode.dark, reason: '$tag theme mode');
        expect(
          theme.accentColor,
          _preAccentReleases.contains(tag) ? AccentColor.blue : AccentColor.teal,
          reason: '$tag accent',
        );
      });

      test('app prefs keep every value the release wrote', () {
        final want = _superset['globalPrefs'] as Map<String, dynamic>;
        for (final e in kExportedAppPrefs.entries) {
          final key = e.key;
          final got = plan.appPrefs[key];
          if (!backup.globalPrefs.containsKey(key)) {
            expect(got, e.value,
                reason: '$tag: "$key" is absent and must take the default');
          } else if (key == kGlobalOutboundProxyKey) {
            final proxy = jsonDecode(got as String) as Map<String, dynamic>;
            final wanted = want[key] as Map<String, dynamic>;
            expect(proxy['type'], wanted['type'], reason: tag);
            expect(proxy['address'], wanted['address'], reason: tag);
            expect(proxy['username'], wanted['username'], reason: tag);
            expect(proxy.containsKey('password'), isFalse, reason: tag);
          } else {
            expect(got, want[key], reason: '$tag: "$key" did not survive');
          }
        }
      });

      test('optional sections', () {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(plan.suggestedSites?.map((s) => s.url).toList(),
            json.containsKey('suggestedSites') ? ['https://example.com'] : null);
        if (json.containsKey('globalUserScripts')) {
          expect(plan.globalUserScripts!.single.id, 'global-script-1');
          expect(plan.globalUserScripts!.single.enabled, isFalse);
        } else {
          expect(plan.globalUserScripts, isNull);
        }
        expect(plan.dnsBlockLevel,
            json.containsKey('dnsBlockLevel') ? _superset['dnsBlockLevel'] : null);
        expect(
          plan.contentBlockerLists,
          json.containsKey('contentBlockerLists')
              ? _superset['contentBlockerLists']
              : null,
        );
        expect(plan.blocklistsNeedDownload, json.containsKey('dnsBlockLevel'));
        expect(plan.proxyPasswordsNeeded, isTrue,
            reason: 'site A names a proxy username in every release');
        expect(plan.extraSections, isEmpty);
      });

      test('export then import again changes nothing', () {
        final first = SettingsBackupService.exportToJson(_reexport(plan));
        final again = planSettingsImport(
            SettingsBackupService.importFromJson(first)!);
        expect([for (final s in again.sites) s.toJson()],
            [for (final s in plan.sites) s.toJson()]);
        expect(again.appPrefs, plan.appPrefs);
        expect(again.themeStorageIndex, plan.themeStorageIndex);
        final second = SettingsBackupService.exportToJson(_reexport(again));
        expect(_withoutTimestamp(second), _withoutTimestamp(first));
      });

      test('minimal backup imports as a fresh site', () {
        final minimal = planSettingsImport(SettingsBackupService.importFromJson(
            _read(tag, 'backup_minimal.json'))!);
        final got = minimal.sites.single.toJson()..remove('siteId');
        final fresh = _freshSiteJson('https://minimal.example/')
          ..remove('siteId');
        expect(got, fresh);
        expect(minimal.appPrefs, resolveExportedAppPrefs(const {}));
        expect(minimal.themeStorageIndex, 0);
        expect(minimal.webspaces.single.isAll, isTrue);
        expect(minimal.selectedWebspaceId, kAllWebspaceId);
      });

      if (_has(tag, 'qr_maximal.txt')) {
        test('site QR link still decodes', () {
          final qr = _read(tag, 'qr_maximal.txt').trim();
          final decoded = SiteSettingsQrCodec.decode(qr);
          expect(decoded, isNotNull, reason: '$tag QR no longer decodes');
          expect(SiteSettingsQrCodec.includedKeys.containsAll(decoded!.keys),
              isTrue);
          final want = _supersetSites.first;
          for (final key in decoded.keys) {
            if (key == 'proxySettings') continue;
            expect(decoded[key], want[key], reason: '$tag QR "$key"');
          }
          final model = WebViewModel.fromJson(
              SiteSettingsQrCodec.hydrateForFromJson(decoded), null);
          expect(model.initUrl, want['initUrl']);
          expect(model.cookies, isEmpty);
          expect(model.userScripts, isEmpty);
          expect(model.proxySettings.password, isNull);
          expect(model.proxySettings.address,
              (want['proxySettings'] as Map)['address']);
        });
      }

      if (_has(tag, 'links.json')) {
        test('webspace://open links parse as they did', () {
          final links =
              (jsonDecode(_read(tag, 'links.json')) as Map).cast<String, String?>();
          for (final e in links.entries) {
            final head = _parseLinkAtHead(e.key);
            expect(head, isNot('!throws'),
                reason: '${e.key} throws instead of being rejected');
            expect(head, e.value == '!throws' ? isNull : e.value,
                reason: '$tag parsed ${e.key} as ${e.value}');
          }
        });
      }
    });
  }

  group('legacy spellings no release wrote', () {
    // Between releases a few keys had an earlier name. Only builds from
    // master between those releases wrote them, but a device that ran one
    // keeps them in storage and in its backups.
    Map<String, dynamic> site(Map<String, dynamic> extra) => {
          'initUrl': 'https://legacy.example/',
          'cookies': const [],
          'proxySettings': {'type': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
          ...extra,
        };
    Map<String, dynamic> backupOf(List<Map<String, dynamic>> sites,
            {Map<String, dynamic> globalPrefs = const {}}) =>
        {
          'version': 1,
          'sites': sites,
          'webspaces': const [],
          'themeMode': 0,
          'globalPrefs': globalPrefs,
        };

    test('cameraAllowed maps to a camera mode, and a grant resets to ask', () {
      expect(WebViewModel.fromJson(site({'cameraAllowed': true}), null).cameraMode,
          CameraAccessMode.real);
      final plan = _planFromJson(backupOf([
        site({'cameraAllowed': true}),
        site({'cameraAllowed': false}),
      ]));
      expect(plan.sites[0].cameraMode, CameraAccessMode.ask);
      expect(plan.sites[1].cameraMode, CameraAccessMode.block);
    });

    test('backgroundPoll maps to notifications, then resets on import', () {
      expect(
          WebViewModel.fromJson(site({'backgroundPoll': true}), null)
              .notificationsEnabled,
          isTrue);
      final plan = _planFromJson(backupOf([site({'backgroundPoll': true})]));
      expect(plan.sites.single.notificationsEnabled, isFalse);
    });

    test('per-site tabBarButtonOnRight maps to a corner', () {
      final plan = _planFromJson(backupOf([
        site({'tabBarButtonOnRight': true}),
        site({'tabBarButtonOnRight': false}),
      ]));
      expect(plan.sites[0].toJson()['tabBarButtonCorner'], 'bottomRight');
      expect(plan.sites[1].toJson()['tabBarButtonCorner'], 'bottomLeft');
    });

    test('fine / coarse location granularity map to gps / gsm', () {
      final plan = _planFromJson(backupOf([
        site({'liveLocationGranularity': 'fine'}),
        site({'liveLocationGranularity': 'coarse'}),
      ]));
      expect(plan.sites[0].liveLocationGranularity, LocationGranularity.gps);
      expect(plan.sites[1].liveLocationGranularity, LocationGranularity.gsm);
    });

    test('tabBarButtonInFullscreen stands in for tabBarButton', () {
      final plan = _planFromJson(backupOf(const [],
          globalPrefs: {'tabBarButtonInFullscreen': true}));
      expect(plan.appPrefs['tabBarButton'], isTrue);
      final newer = _planFromJson(backupOf(const [], globalPrefs: {
        'tabBarButtonInFullscreen': true,
        'tabBarButton': false,
      }));
      expect(newer.appPrefs['tabBarButton'], isFalse,
          reason: 'the current key wins when both are present');
    });

    test('a secure cookie in a hand-written file is kept, then never exported',
        () {
      final plan = _planFromJson(backupOf([
        site({
          'cookies': [
            {
              'name': '__Host-session',
              'value': 'secure-cookie-needle-5d1e',
              'domain': 'legacy.example',
              'path': '/',
              'isSecure': true,
            },
          ],
        }),
      ]));
      expect(plan.sites.single.cookies.single.value, 'secure-cookie-needle-5d1e',
          reason: 'imported cookies go to secure storage with the site');
      final exported = SettingsBackupService.exportToJson(_reexport(plan));
      expect(exported.contains('secure-cookie-needle-5d1e'), isFalse);
    });
  });

  group('malformed and hostile input', () {
    Map<String, dynamic> site([Map<String, dynamic> extra = const {}]) => {
          'initUrl': 'https://edge.example/',
          'cookies': const [],
          'proxySettings': {'type': 0},
          'javascriptEnabled': true,
          'userAgent': '',
          'thirdPartyCookiesEnabled': false,
          ...extra,
        };
    Map<String, dynamic> backupOf({
      List<Object?>? sites,
      List<Object?> webspaces = const [],
      Map<String, Object?> extra = const {},
    }) =>
        {
          'version': 1,
          'sites': sites ?? [site()],
          'webspaces': webspaces,
          'themeMode': 0,
          ...extra,
        };
    SettingsImportPlan plan(Map<String, dynamic> json) {
      final p = _planFromJson(json);
      _expectSanitised(p, reason: 'edge case');
      return p;
    }

    group('rejected whole, before anything is applied', () {
      for (final (name, text) in [
        ('empty file', ''),
        ('not JSON', 'webspace backup'),
        ('top-level array', '[]'),
        ('top-level null', 'null'),
        ('no sites', jsonEncode({'version': 1, 'webspaces': [], 'themeMode': 0})),
        ('sites not a list', jsonEncode({'sites': {}, 'webspaces': []})),
        ('a site that is not an object', jsonEncode({'sites': [1], 'webspaces': []})),
        ('no webspaces', jsonEncode({'sites': [], 'themeMode': 0})),
      ]) {
        test(name, () {
          expect(SettingsBackupService.importFromJson(text), isNull);
        });
      }

      for (final (name, bad) in [
        ('a site without initUrl', site()..remove('initUrl')),
        ('a numeric initUrl', site({'initUrl': 42})),
      ]) {
        test(name, () {
          final backup = SettingsBackupService.importFromJson(
              jsonEncode(backupOf(sites: [site(), bad])));
          expect(backup, isNotNull);
          expect(() => planSettingsImport(backup!), throwsA(anything));
        });
      }
    });

    test('a UTF-8 BOM does not reject the file', () {
      final text = '﻿${jsonEncode(backupOf())}';
      expect(SettingsBackupService.importFromJson(text), isNotNull);
    });

    test('mistyped optional fields read as absent', () {
      final p = plan(backupOf(extra: {
        'version': 'two',
        'themeMode': 'dark',
        'currentIndex': '0',
        'selectedWebspaceId': 7,
        'exportedAt': 'yesterday',
        'globalPrefs': ['not', 'a', 'map'],
        'suggestedSites': 'none',
        'globalUserScripts': {'id': 'x'},
        'dnsBlockLevel': '3',
        'contentBlockerLists': 5,
        'extraSections': [1, 'section', null],
      }));
      expect(p.themeStorageIndex, 0);
      expect(p.currentIndex, isNull);
      expect(p.selectedWebspaceId, kAllWebspaceId);
      expect(p.appPrefs, resolveExportedAppPrefs(const {}));
      expect(p.suggestedSites, isNull);
      expect(p.globalUserScripts, isNull);
      expect(p.dnsBlockLevel, isNull);
      expect(p.contentBlockerLists, isNull);
      expect(p.extraSections, ['section']);
    });

    test('a newer backup version still imports', () {
      expect(plan(backupOf(extra: {'version': 99})).sites, hasLength(1));
    });

    test('out-of-range scalars fall back', () {
      for (final theme in [-15, -1, 3, 29, 99, 1 << 40]) {
        final p = plan(backupOf(extra: {'themeMode': theme}));
        expect(() => AppThemeSettings.fromStorageIndex(p.themeStorageIndex),
            returnsNormally, reason: 'themeMode $theme');
      }
      for (final index in [-1, 1, 99]) {
        expect(plan(backupOf(extra: {'currentIndex': index})).currentIndex,
            isNull, reason: 'currentIndex $index');
      }
      for (final level in [-1, 6, 99]) {
        expect(plan(backupOf(extra: {'dnsBlockLevel': level})).dnsBlockLevel,
            isNull, reason: 'dnsBlockLevel $level');
      }
      expect(plan(backupOf(extra: {'selectedWebspaceId': 'gone'}))
          .selectedWebspaceId, kAllWebspaceId);
    });

    test('a legacy theme index is told apart from the current encoding', () {
      final legacySite = site()..remove('language');
      final withLanguage = site({'language': null});
      for (final (raw, sites, want) in [
        (2, [legacySite], 20),
        (1, [legacySite], 10),
        (0, [legacySite], 0),
        (2, [withLanguage], 2),
        (26, [legacySite], 26),
        (2, <Map<String, dynamic>>[], 2),
      ]) {
        expect(normalizeBackupThemeIndex(raw, sites), want,
            reason: 'raw $raw with ${sites.length} site(s)');
      }
    });

    test('prefs are stored under the registry type', () {
      final p = plan(backupOf(extra: {
        'globalPrefs': {
          'showUrlBar': 'true',
          'tabMaxWidth': 180.0,
          'showTabStrip': 1,
          'appLocaleOverride': 5,
          'osmTileUrl': null,
        },
      }));
      expect(p.appPrefs['showUrlBar'], false);
      expect(p.appPrefs['tabMaxWidth'], 180);
      expect(p.appPrefs['showTabStrip'], false);
      expect(p.appPrefs['appLocaleOverride'], '');
      expect(p.appPrefs['osmTileUrl'], kExportedAppPrefs['osmTileUrl']);
      // A file can spell a number JSON-encoding cannot produce.
      final overflow = SettingsBackupService.importFromJson(
          '{"sites": [], "webspaces": [], "globalPrefs": {"tabMaxWidth": 1e400}}');
      expect(planSettingsImport(overflow!).appPrefs['tabMaxWidth'],
          kExportedAppPrefs['tabMaxWidth']);
      for (final width in [180.5, 'wide', true]) {
        expect(
          plan(backupOf(extra: {'globalPrefs': {'tabMaxWidth': width}}))
              .appPrefs['tabMaxWidth'],
          kExportedAppPrefs['tabMaxWidth'],
          reason: 'tabMaxWidth $width',
        );
      }
    });

    test('the app-wide proxy cannot bring a password', () {
      final p = plan(backupOf(extra: {
        'globalPrefs': {
          kGlobalOutboundProxyKey: jsonEncode({
            'type': ProxyType.SOCKS5.index,
            'address': 'attacker.example:1080',
            'username': 'u',
            'password': 'global-proxy-password-needle-9e2d',
          }),
        },
      }));
      final stored = p.appPrefs[kGlobalOutboundProxyKey] as String;
      expect(stored.contains('global-proxy-password-needle-9e2d'), isFalse);
      expect(jsonDecode(stored)['address'], 'attacker.example:1080');
      expect(p.proxyPasswordsNeeded, isTrue);
      for (final junk in ['', 'not json', '[1]', '42']) {
        final q = plan(backupOf(extra: {
          'globalPrefs': {kGlobalOutboundProxyKey: junk},
        }));
        expect(q.appPrefs[kGlobalOutboundProxyKey], junk);
      }
    });

    test('TLS pins in globalPrefs are not installed', () {
      final p = plan(backupOf(extra: {
        'globalPrefs': {
          kTrustedHostsKey: ['evil.example|443|tls-pin-needle-c0de'],
        },
      }));
      expect(p.appPrefs.containsKey(kTrustedHostsKey), isFalse);
    });

    test('siteIds are made unique and path-safe', () {
      final p = plan(backupOf(sites: [
        site({'siteId': 'dup', 'name': 'first'}),
        site({'siteId': 'dup', 'name': 'second'}),
        site({'siteId': '../../escape', 'name': 'unsafe'}),
        site({'siteId': 12, 'name': 'numeric'}),
      ], webspaces: [
        {'id': 'ws', 'name': 'W', 'siteIds': ['dup']},
      ]));
      expect(p.sites[0].siteId, 'dup');
      expect(p.sites[1].siteId, isNot('dup'));
      expect(p.sites[2].siteId, isNot(contains('..')));
      expect(p.webspaces[1].siteIds, ['dup'],
          reason: 'membership stays with the site that kept the id');
    });

    test('webspace membership is cleaned', () {
      final p = plan(backupOf(sites: [
        site({'siteId': 'a'}),
        site({'siteId': 'b'}),
      ], webspaces: [
        {'id': 'ws', 'name': 'Ids', 'siteIds': ['a', 'gone', 'a', 7, 'b']},
        {'id': 'ws', 'name': 'Same id'},
        {'id': kAllWebspaceId, 'name': 'All again', 'siteIds': ['a']},
        {'id': 'legacy', 'name': 'Indices', 'siteIndices': [1, -1, 5, 'x', 0]},
        {'id': 'unnamed', 'siteIds': ['b']},
      ]));
      final ws = p.webspaces;
      expect(ws.where((w) => w.isAll), hasLength(1));
      expect(ws.map((w) => w.id).toSet(), hasLength(ws.length),
          reason: 'webspace ids must be unique');
      expect(ws.firstWhere((w) => w.name == 'Ids').siteIds, ['a', 'b']);
      expect(ws.firstWhere((w) => w.name == 'Indices').siteIds, ['b', 'a']);
      expect(ws.firstWhere((w) => w.id == 'unnamed').name, 'Untitled');
    });

    test('malformed optional entries are dropped, not fatal', () {
      final p = plan(backupOf(extra: {
        'suggestedSites': [
          {'name': 'ok', 'url': 'https://ok.example', 'domain': 'ok.example'},
          {'name': 'no domain', 'url': 'https://x.example'},
          'not a map',
        ],
        'globalUserScripts': [
          {'id': 'ok', 'name': 'ok', 'source': '1', 'enabled': true},
          {'id': 5, 'name': 'bad id'},
          'not a map',
        ],
        'contentBlockerLists': [
          {'id': 7, 'name': 'x', 'url': 'https://x', 'enabled': 'yes'},
          {'id': 'easylist', 'name': 'EasyList', 'url': 'https://e', 'enabled': true},
        ],
      }));
      expect(p.suggestedSites!.map((s) => s.name), ['ok']);
      expect(p.globalUserScripts!.map((s) => s.name), ['ok', 'bad id'],
          reason: 'a script with a mistyped id is kept under a fresh one');
      expect(p.globalUserScripts![1].id, isNot('5'));
      expect(p.globalUserScripts!.where((s) => s.enabled), isEmpty);
      expect(p.contentBlockerLists![0]['id'], isNull);
      expect(p.contentBlockerLists![0]['enabled'], isFalse);
      expect(p.contentBlockerLists![1]['enabled'], isTrue);
    });

    test('per-site values are sanitised on the way in', () {
      final p = plan(backupOf(sites: [
        site({
          'incognito': true,
          'currentUrl': 'https://edge.example/private',
          'pageTitle': 'Private',
          'cookies': [
            {'name': 'c', 'value': 'incognito-cookie-needle-77b0', 'domain': 'edge.example'},
          ],
        }),
        site({
          'alwaysOpenHome': true,
          'currentUrl': 'https://edge.example/deep',
          'cookies': [
            {'name': 'keep', 'value': 'v', 'domain': 'edge.example'},
          ],
        }),
        site({
          'language': 'en\r\nX-Injected: 1',
          'zoomPercent': 100000,
          'customIconPng': 'not base64!',
          'dnsBlockLevel': 42,
          'proxySettings': {'type': 99, 'address': 'x', 'password': 'p'},
          'cameraMode': 'virtual',
          'virtualCameraSource': {
            'kind': 'image',
            'dataUrl': 'file:///etc/passwd',
            'fileName': 'x',
          },
          'microphoneMode': 'real',
          'screenShareMode': 'real',
          'locationMode': 'live',
          'notificationsEnabled': true,
          'backgroundAudioEnabled': true,
          'protectedContentAllowed': true,
          'userScripts': [
            {'id': 's', 'name': 's', 'source': 'x', 'enabled': true, 'bypassSitePolicy': true},
          ],
          'enabledGlobalScriptIds': ['g'],
        }),
      ]));
      final incognito = p.sites[0].toJson();
      expect(incognito['currentUrl'], isNull);
      expect(incognito['pageTitle'], isNull);
      expect(p.sites[0].cookies, isEmpty);
      expect(p.sites[1].toJson()['currentUrl'], isNull);
      expect(p.sites[1].cookies.single.name, 'keep');
      final hostile = p.sites[2];
      expect(hostile.language, isNull);
      expect(hostile.zoomPercent, kMaxZoomPercent);
      expect(hostile.customIconPng, isNull);
      expect(hostile.dnsBlockLevel, isNull);
      expect(hostile.proxySettings.type, ProxyType.DEFAULT);
      expect(hostile.virtualCameraSource, isNull);
      expect(hostile.toJson()['screenShareMode'], isNull,
          reason: 'there is no real screen-share mode to restore');
    });
  });

  group('one odd value never costs a site', () {
    // At startup a site whose JSON throws is skipped and the next save
    // deletes it; on import it rejects the whole file. So every field but
    // initUrl must survive any value, and must not take its neighbours
    // with it.
    const junk = <Object?>[
      null, true, false, 0, 7, -1, 1.5, '', 'x', <Object?>[], <Object?>[1],
      <String, Object?>{}, <String, Object?>{'a': 1},
    ];
    final base = WebViewModel.fromJson(
            jsonDecode(jsonEncode(_supersetSites.first)) as Map<String, dynamic>,
            null)
        .toJson();
    final baseline = WebViewModel.fromJson(
            jsonDecode(jsonEncode(base)) as Map<String, dynamic>, null)
        .toJson();

    Map<String, dynamic> loaded(Map<String, dynamic> json) =>
        WebViewModel.fromJson(
                jsonDecode(jsonEncode(json)) as Map<String, dynamic>, null)
            .toJson();

    test('the baseline round-trips', () {
      expect(baseline, base);
    });

    for (final key in base.keys.where((k) => k != 'initUrl')) {
      test('"$key" of any type', () {
        for (final value in [...junk, #absent]) {
          if (value != #absent &&
              value != null &&
              value.runtimeType == base[key].runtimeType) {
            continue;
          }
          final json = Map<String, dynamic>.from(base);
          if (value == #absent) {
            json.remove(key);
          } else {
            json[key] = value;
          }
          final Map<String, dynamic> out;
          try {
            out = loaded(json);
          } catch (e) {
            fail('"$key": $value threw $e');
          }
          expect(() => jsonEncode(out), returnsNormally);
          for (final other in baseline.keys) {
            if (other == key || other == 'siteId') continue;
            expect(out[other], baseline[other],
                reason: '"$key": $value changed "$other"');
          }
        }
      });
    }

    test('initUrl is the one required field', () {
      for (final value in [...junk.where((v) => v is! String), #absent]) {
        final json = Map<String, dynamic>.from(base);
        if (value == #absent) {
          json.remove('initUrl');
        } else {
          json['initUrl'] = value;
        }
        expect(() => WebViewModel.fromJson(json, null), throwsA(anything),
            reason: 'initUrl $value');
      }
    });

    test('a bad entry in a list keeps the others', () {
      final json = Map<String, dynamic>.from(base);
      for (final key in ['cookies', 'userScripts', 'blockedCookies', 'domainClaims']) {
        json[key] = [...junk, ...(base[key] as List)];
      }
      final out = loaded(json);
      for (final key in ['cookies', 'blockedCookies', 'domainClaims']) {
        expect(out[key], baseline[key], reason: key);
      }
      final scripts = out['userScripts'] as List;
      expect(scripts.last, (baseline['userScripts'] as List).single);
    });

    test('a proxy field of any type', () {
      final proxy = base['proxySettings'] as Map<String, dynamic>;
      for (final key in [...proxy.keys, 'password', 'torExitCountry']) {
        for (final value in junk) {
          final json = Map<String, dynamic>.from(base)
            ..['proxySettings'] = {...proxy, key: value};
          final Map<String, dynamic> out;
          try {
            out = loaded(json);
          } catch (e) {
            fail('proxySettings.$key: $value threw $e');
          }
          for (final other in baseline.keys) {
            if (other == 'proxySettings' || other == 'siteId') continue;
            expect(out[other], baseline[other],
                reason: 'proxySettings.$key: $value changed "$other"');
          }
        }
      }
    });

    test('a user-script field of any type keeps the script', () {
      final script = (base['userScripts'] as List).single as Map<String, dynamic>;
      for (final key in [...script.keys, 'url', 'urlSource']) {
        for (final value in junk) {
          final json = Map<String, dynamic>.from(base)
            ..['userScripts'] = [
              {...script, key: value},
            ];
          final scripts = loaded(json)['userScripts'] as List;
          expect(scripts, hasLength(1), reason: 'userScripts.$key: $value');
          if (key != 'source') {
            expect((scripts.single as Map)['source'], script['source'],
                reason: 'userScripts.$key: $value lost the source');
          }
        }
      }
    });

    test('a QR link naming only a URL creates a site', () {
      // `decode` requires only initUrl, so a hand-built webspace://qr/ link
      // can omit everything else; applying it used to throw on the
      // non-nullable javascriptEnabled.
      final link = SiteSettingsQrCodec.encode({'initUrl': 'https://qr.example/'});
      final decoded = SiteSettingsQrCodec.decode(link)!;
      final model = WebViewModel.fromJson(
          SiteSettingsQrCodec.hydrateForFromJson(decoded), null);
      expect(model.initUrl, 'https://qr.example/');
      expect(model.javascriptEnabled, isTrue);
      expect(model.proxySettings.type, ProxyType.DEFAULT);
    });

    test('a webspace field of any type', () {
      for (final key in ['id', 'name', 'siteIds', 'siteIndices']) {
        for (final value in junk) {
          expect(
            () => Webspace.fromJson({
              'id': 'w',
              'name': 'Work',
              'siteIds': ['a'],
              key: value,
            }),
            returnsNormally,
            reason: 'webspace $key: $value',
          );
        }
      }
    });
  });

  group('stored prefs of the wrong type', () {
    // v0.2.2 to v0.3.1 imports stored globalPrefs values under the file's
    // JSON type. The typed getters throw on those; startup must not.
    setUp(() {
      SharedPreferences.setMockInitialValues({
        for (final e in kExportedAppPrefs.entries)
          e.key: e.value is String ? 42 : 'not-${e.value.runtimeType}',
      });
    });

    test('readExportedAppPrefs falls back to every default', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(readExportedAppPrefs(prefs), kExportedAppPrefs);
    });

    test('readPrefAs never throws', () async {
      final prefs = await SharedPreferences.getInstance();
      for (final key in kExportedAppPrefs.keys) {
        expect(readPrefAs<bool>(prefs, key), isNull);
        expect(readPrefAs<int>(prefs, key), anyOf(isNull, 42));
      }
    });

    test('startup reads exported prefs only through readPrefAs', () {
      final restore = _region('lib/main.dart',
          'Future<void> _restoreAppState() async {', 'await _loadWebspaces();');
      expect(
        RegExp(r'prefs\.get(Bool|Int|Double|String|StringList)\(').hasMatch(restore),
        isFalse,
        reason: 'a typed getter throws on a mistyped stored value',
      );
    });
  });

  test('a backup carrying every secret imports clean', () {
    // Security holds for any input; this is the current format with every
    // secret and grant the rules exist for, rather than one per release.
    final sites = [
      for (final s in _supersetSites)
        WebViewModel.fromJson(jsonDecode(jsonEncode(s)) as Map<String, dynamic>, null),
    ];
    final json = jsonDecode(SettingsBackupService.exportToJson(
        SettingsBackupService.createBackup(
      webViewModels: sites,
      webspaces: [Webspace.all()],
      themeMode: 0,
      globalPrefs: {
        kGlobalOutboundProxyKey: jsonEncode(
            (_superset['globalPrefs'] as Map)[kGlobalOutboundProxyKey]),
        kTrustedHostsKey: (_superset['globalPrefs'] as Map)[kTrustedHostsKey],
      },
      globalUserScripts: [
        for (final s in _superset['globalUserScripts'] as List)
          s as Map<String, dynamic>,
      ],
    ))) as Map<String, dynamic>;
    for (var i = 0; i < _supersetSites.length; i++) {
      final site = json['sites'][i] as Map<String, dynamic>;
      site['cookies'] = _supersetSites[i]['cookies'];
      site['proxySettings'] = _supersetSites[i]['proxySettings'];
    }
    final plan = _planFromJson(json);
    _expectSanitised(plan, reason: 'maximal hostile backup');
    final text = SettingsBackupService.exportToJson(_reexport(plan)) +
        jsonEncode(plan.appPrefs);
    for (final needle in _needles) {
      expect(text.contains(needle), isFalse, reason: '"$needle" survived');
    }
  });

  group('gates', () {
    test('the version in pubspec.yaml has release fixtures', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*([0-9.]+)', multiLine: true)
          .firstMatch(pubspec)!
          .group(1)!;
      for (final name in ['backup_maximal.json', 'backup_minimal.json']) {
        expect(_has('v$version', name), isTrue,
            reason: 'v$version has no $name. On release day run '
                'tool/backup_compat/generate.sh HEAD (or the new tag).');
      }
    });

    test('fixtures stay small', () {
      for (final tag in tags) {
        var total = 0;
        for (final f in Directory('$_fixtureRoot/$tag').listSync().whereType<File>()) {
          final size = f.lengthSync();
          total += size;
          expect(size, lessThan(16 * 1024),
              reason: '${f.path} is $size bytes; keep superset.json values '
                  'tiny (1x1 images, short strings)');
        }
        expect(total, lessThan(32 * 1024), reason: '$tag is $total bytes');
      }
    });

    test('every legacy key the importer reads is exercised by a fixture', () {
      // A key `fromJson` still reads but the current `toJson` no longer
      // writes is a migration. Each one must appear in some fixture, or the
      // migration is untested code waiting to rot.
      final reads = {
        ..._readKeys(_region('lib/web_view_model.dart',
            'factory WebViewModel.fromJson(', '\n  }\n')),
        ..._readKeys(_region('lib/services/settings_backup.dart',
            'factory SettingsBackup.fromJson(', '\n  }\n')),
        ..._matches(
            _region('lib/services/settings_backup.dart',
                "for (final key in const [", ']'),
            r"'(\w+)'"),
        ..._readKeys(_region(
            'lib/webspace_model.dart', 'factory Webspace.fromJson(', '\n  }\n')),
        ..._readKeys(File('lib/settings/app_prefs.dart').readAsStringSync()),
      };
      final writes = {
        ..._matches(
            _region('lib/web_view_model.dart', "'siteId': siteId",
                'factory WebViewModel.fromJson('),
            r"'(\w+)':"),
        ..._matches(
            _region('lib/services/settings_backup.dart',
                'Map<String, dynamic> toJson() => {', '};'),
            r"'(\w+)':"),
        ..._matches(
            _region('lib/webspace_model.dart', 'Map<String, dynamic> toJson()',
                '};'),
            r"'(\w+)':"),
        ...kExportedAppPrefs.keys,
      };
      final legacy = reads.difference(writes);
      expect(legacy, isNotEmpty, reason: 'the scan found nothing to check');

      final corpus = StringBuffer(
          File('test/settings_backup_compat_test.dart').readAsStringSync());
      for (final tag in tags) {
        corpus.write(_read(tag, 'backup_maximal.json'));
      }
      final text = corpus.toString();
      final untested = [
        for (final key in legacy)
          if (!text.contains("'$key'") && !text.contains('"$key"')) key,
      ];
      expect(untested, isEmpty,
          reason: 'fromJson migrates these keys but no fixture carries them');
    });
  });
}
