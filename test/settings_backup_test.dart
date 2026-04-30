import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';

void main() {
  group('SettingsBackup Model', () {
    test('should serialize to JSON correctly', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [
          {'initUrl': 'https://example.com', 'name': 'Example'}
        ],
        webspaces: [
          {'id': 'ws-1', 'name': 'Work', 'siteIndices': [0]}
        ],
        themeMode: 2,
        showUrlBar: true,
        selectedWebspaceId: 'ws-1',
        currentIndex: 0,
        exportedAt: DateTime(2024, 1, 15, 10, 30),
      );

      final json = backup.toJson();

      expect(json['version'], equals(1));
      expect(json['sites'], hasLength(1));
      expect(json['webspaces'], hasLength(1));
      expect(json['themeMode'], equals(2));
      expect((json['globalPrefs'] as Map)['showUrlBar'], equals(true));
      expect(json['selectedWebspaceId'], equals('ws-1'));
      expect(json['currentIndex'], equals(0));
      expect(json['exportedAt'], equals('2024-01-15T10:30:00.000'));
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'version': 1,
        'sites': [
          {'initUrl': 'https://test.com', 'name': 'Test'}
        ],
        'webspaces': [
          {'id': 'ws-2', 'name': 'Personal', 'siteIndices': [0, 1]}
        ],
        'themeMode': 1,
        'showUrlBar': false,
        'selectedWebspaceId': '__all_webspace__',
        'currentIndex': null,
        'exportedAt': '2024-02-20T15:45:00.000Z',
      };

      final backup = SettingsBackup.fromJson(json);

      expect(backup.version, equals(1));
      expect(backup.sites, hasLength(1));
      expect(backup.webspaces, hasLength(1));
      expect(backup.themeMode, equals(1));
      expect(backup.showUrlBar, equals(false));
      expect(backup.selectedWebspaceId, equals('__all_webspace__'));
      expect(backup.currentIndex, isNull);
    });

    test('should handle missing optional fields', () {
      final json = {
        'sites': [],
        'webspaces': [],
      };

      final backup = SettingsBackup.fromJson(json);

      expect(backup.version, equals(1)); // Default
      expect(backup.themeMode, equals(0)); // Default
      expect(backup.showUrlBar, equals(false)); // Default
      expect(backup.selectedWebspaceId, isNull);
      expect(backup.currentIndex, isNull);
    });

    test('should round-trip through JSON correctly', () {
      final original = SettingsBackup(
        version: 1,
        sites: [
          {'url': 'https://a.com'},
          {'url': 'https://b.com'},
        ],
        webspaces: [
          {'id': 'w1', 'name': 'W1', 'siteIndices': [0]},
        ],
        themeMode: 2,
        showUrlBar: true,
        selectedWebspaceId: 'w1',
        currentIndex: 1,
        exportedAt: DateTime.now(),
      );

      final jsonString = jsonEncode(original.toJson());
      final restored = SettingsBackup.fromJson(jsonDecode(jsonString));

      expect(restored.version, equals(original.version));
      expect(restored.sites.length, equals(original.sites.length));
      expect(restored.webspaces.length, equals(original.webspaces.length));
      expect(restored.themeMode, equals(original.themeMode));
      expect(restored.showUrlBar, equals(original.showUrlBar));
      expect(restored.selectedWebspaceId, equals(original.selectedWebspaceId));
      expect(restored.currentIndex, equals(original.currentIndex));
    });
  });

  group('SettingsBackupService.createBackup', () {
    test('should create backup with all settings', () {
      final webViewModels = [
        WebViewModel(initUrl: 'https://example.com', name: 'Example'),
        WebViewModel(initUrl: 'https://test.com', name: 'Test'),
      ];
      final webspaces = [
        Webspace.all(),
        Webspace(id: 'work', name: 'Work', siteIndices: [0]),
      ];

      final backup = SettingsBackupService.createBackup(
        webViewModels: webViewModels,
        webspaces: webspaces,
        themeMode: 1,
        showUrlBar: true,
        selectedWebspaceId: 'work',
        currentIndex: 0,
      );

      expect(backup.version, equals(kBackupVersion));
      expect(backup.sites, hasLength(2));
      expect(backup.webspaces, hasLength(1)); // "All" excluded
      expect(backup.themeMode, equals(1));
      expect(backup.showUrlBar, equals(true));
      expect(backup.selectedWebspaceId, equals('work'));
      expect(backup.currentIndex, equals(0));
    });

    test('should export only non-secure cookies', () {
      final modelWithCookies = WebViewModel(
        initUrl: 'https://example.com',
        cookies: [
          Cookie(name: 'session', value: 'secret123', isSecure: true),
          Cookie(name: 'theme', value: 'dark', isSecure: false),
          Cookie(name: 'prefs', value: 'abc'),  // isSecure defaults to null/false
        ],
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: [modelWithCookies],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      // Only non-secure cookies should be in the backup
      final cookies = backup.sites[0]['cookies'] as List;
      expect(cookies, hasLength(2));
      expect(cookies.map((c) => c['name']).toSet(), equals({'theme', 'prefs'}));
    });

    test('should exclude all cookies if all are secure', () {
      final modelWithCookies = WebViewModel(
        initUrl: 'https://example.com',
        cookies: [
          Cookie(name: 'session', value: 'secret123', isSecure: true),
          Cookie(name: 'auth', value: 'token456', isSecure: true),
        ],
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: [modelWithCookies],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      // No cookies should be in the backup (all were secure)
      expect(backup.sites[0]['cookies'], isEmpty);
    });

    test('should exclude "All" webspace from export', () {
      final webspaces = [
        Webspace.all(),
        Webspace(name: 'Custom1'),
        Webspace(name: 'Custom2'),
      ];

      final backup = SettingsBackupService.createBackup(
        webViewModels: [],
        webspaces: webspaces,
        themeMode: 0,
        showUrlBar: false,
      );

      // Only custom webspaces should be exported
      expect(backup.webspaces, hasLength(2));
      expect(backup.webspaces.every((ws) => ws['id'] != kAllWebspaceId), isTrue);
    });

    test('should preserve site settings with non-secure cookies only', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        currentUrl: 'https://example.com/page',
        name: 'My Site',
        cookies: [
          Cookie(name: 'secure_token', value: 'secret', isSecure: true),
          Cookie(name: 'theme', value: 'dark', isSecure: false),
        ],
        proxySettings: UserProxySettings(type: ProxyType.SOCKS5, address: 'localhost:9050'),
        javascriptEnabled: false,
        userAgent: 'Custom/1.0',
        thirdPartyCookiesEnabled: true,
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: [model],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final siteJson = backup.sites[0];
      expect(siteJson['initUrl'], equals('https://example.com'));
      expect(siteJson['currentUrl'], equals('https://example.com/page'));
      expect(siteJson['name'], equals('My Site'));
      // Only non-secure cookie exported
      final cookies = siteJson['cookies'] as List;
      expect(cookies, hasLength(1));
      expect(cookies[0]['name'], equals('theme'));
      expect(siteJson['javascriptEnabled'], equals(false));
      expect(siteJson['userAgent'], equals('Custom/1.0'));
      expect(siteJson['thirdPartyCookiesEnabled'], equals(true));
      expect(siteJson['proxySettings']['type'], equals(ProxyType.SOCKS5.index));
    });

    test('should handle empty data', () {
      final backup = SettingsBackupService.createBackup(
        webViewModels: [],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
      );

      expect(backup.sites, isEmpty);
      expect(backup.webspaces, isEmpty);
    });
  });

  group('SettingsBackupService.exportToJson', () {
    test('should produce valid JSON string', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [{'url': 'https://test.com'}],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime(2024, 1, 1),
      );

      final jsonString = SettingsBackupService.exportToJson(backup);

      expect(() => jsonDecode(jsonString), returnsNormally);
    });

    test('should produce pretty-printed JSON', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime(2024, 1, 1),
      );

      final jsonString = SettingsBackupService.exportToJson(backup);

      expect(jsonString.contains('\n'), isTrue);
      expect(jsonString.contains('  '), isTrue);
    });
  });

  group('SettingsBackupService.importFromJson', () {
    test('should parse valid JSON', () {
      final jsonString = '''
      {
        "version": 1,
        "sites": [{"initUrl": "https://example.com"}],
        "webspaces": [],
        "themeMode": 2,
        "showUrlBar": true,
        "exportedAt": "2024-01-01T00:00:00.000"
      }
      ''';

      final backup = SettingsBackupService.importFromJson(jsonString);

      expect(backup, isNotNull);
      expect(backup!.version, equals(1));
      expect(backup.sites, hasLength(1));
      expect(backup.themeMode, equals(2));
    });

    test('should return null for invalid JSON', () {
      final backup = SettingsBackupService.importFromJson('not valid json');

      expect(backup, isNull);
    });

    test('should return null for empty string', () {
      final backup = SettingsBackupService.importFromJson('');

      expect(backup, isNull);
    });

    test('should return null for JSON missing required fields', () {
      final backup = SettingsBackupService.importFromJson('{"foo": "bar"}');

      // This should fail because 'sites' is required
      expect(backup, isNull);
    });
  });

  group('SettingsBackupService.restoreSites', () {
    test('should restore WebViewModels from backup', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [
          {
            'initUrl': 'https://example.com',
            'currentUrl': 'https://example.com',
            'name': 'Example',
            'pageTitle': 'Example Page',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
          }
        ],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final sites = SettingsBackupService.restoreSites(backup, null);

      expect(sites, hasLength(1));
      expect(sites[0].initUrl, equals('https://example.com'));
      expect(sites[0].name, equals('Example'));
      expect(sites[0].cookies, isEmpty);
    });

    test('should restore non-secure cookies from backup', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [
          {
            'initUrl': 'https://example.com',
            'currentUrl': 'https://example.com',
            'name': 'Test',
            'cookies': [
              {'name': 'theme', 'value': 'dark', 'isSecure': false},
              {'name': 'prefs', 'value': 'abc'},
            ],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
          }
        ],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final sites = SettingsBackupService.restoreSites(backup, null);

      // Non-secure cookies should be restored
      expect(sites[0].cookies, hasLength(2));
      expect(sites[0].cookies.map((c) => c.name).toSet(), equals({'theme', 'prefs'}));
    });

    test('should restore multiple sites', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [
          {
            'initUrl': 'https://a.com',
            'currentUrl': 'https://a.com',
            'name': 'A',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
          },
          {
            'initUrl': 'https://b.com',
            'currentUrl': 'https://b.com',
            'name': 'B',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
          },
          {
            'initUrl': 'https://c.com',
            'currentUrl': 'https://c.com',
            'name': 'C',
            'cookies': [],
            'proxySettings': {'type': 0, 'address': null},
            'javascriptEnabled': true,
            'userAgent': '',
            'thirdPartyCookiesEnabled': false,
          },
        ],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final sites = SettingsBackupService.restoreSites(backup, null);

      expect(sites, hasLength(3));
      expect(sites[0].initUrl, equals('https://a.com'));
      expect(sites[1].initUrl, equals('https://b.com'));
      expect(sites[2].initUrl, equals('https://c.com'));
    });
  });

  group('SettingsBackupService.restoreWebspaces', () {
    test('should restore webspaces with "All" at the start', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [
          {'id': 'ws-1', 'name': 'Work', 'siteIndices': [0, 1]},
          {'id': 'ws-2', 'name': 'Personal', 'siteIndices': [2]},
        ],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final webspaces = SettingsBackupService.restoreWebspaces(backup);

      expect(webspaces, hasLength(3)); // "All" + 2 custom
      expect(webspaces[0].id, equals(kAllWebspaceId));
      expect(webspaces[0].name, equals('All'));
      expect(webspaces[1].name, equals('Work'));
      expect(webspaces[2].name, equals('Personal'));
    });

    test('should skip "All" webspace if somehow in backup', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [
          {'id': kAllWebspaceId, 'name': 'All', 'siteIndices': []},
          {'id': 'ws-1', 'name': 'Custom', 'siteIndices': [0]},
        ],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final webspaces = SettingsBackupService.restoreWebspaces(backup);

      // Should have exactly one "All" (auto-created) + one custom
      expect(webspaces, hasLength(2));
      expect(webspaces.where((ws) => ws.id == kAllWebspaceId).length, equals(1));
    });

    test('should handle empty webspaces list', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final webspaces = SettingsBackupService.restoreWebspaces(backup);

      // Should still have "All" webspace
      expect(webspaces, hasLength(1));
      expect(webspaces[0].id, equals(kAllWebspaceId));
    });

    test('should preserve webspace site indices', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [
          {'id': 'ws-1', 'name': 'Mixed', 'siteIndices': [0, 2, 5, 10]},
        ],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime.now(),
      );

      final webspaces = SettingsBackupService.restoreWebspaces(backup);

      expect(webspaces[1].siteIndices, equals([0, 2, 5, 10]));
    });
  });

  group('Export/Import Round-trip', () {
    test('should preserve all data through export and import', () {
      // Create original data
      final originalSites = [
        WebViewModel(
          initUrl: 'https://example.com',
          currentUrl: 'https://example.com/page',
          name: 'Example',
          javascriptEnabled: false,
          userAgent: 'Custom/1.0',
          thirdPartyCookiesEnabled: true,
          proxySettings: UserProxySettings(type: ProxyType.HTTP, address: 'proxy:8080'),
        ),
      ];
      final originalWebspaces = [
        Webspace.all(),
        Webspace(id: 'work', name: 'Work', siteIndices: [0]),
      ];

      // Export
      final backup = SettingsBackupService.createBackup(
        webViewModels: originalSites,
        webspaces: originalWebspaces,
        themeMode: 2,
        showUrlBar: true,
        selectedWebspaceId: 'work',
        currentIndex: 0,
      );
      final jsonString = SettingsBackupService.exportToJson(backup);

      // Import
      final importedBackup = SettingsBackupService.importFromJson(jsonString);
      expect(importedBackup, isNotNull);

      final restoredSites = SettingsBackupService.restoreSites(importedBackup!, null);
      final restoredWebspaces = SettingsBackupService.restoreWebspaces(importedBackup);

      // Verify sites
      expect(restoredSites, hasLength(1));
      expect(restoredSites[0].initUrl, equals('https://example.com'));
      expect(restoredSites[0].currentUrl, equals('https://example.com/page'));
      expect(restoredSites[0].name, equals('Example'));
      expect(restoredSites[0].javascriptEnabled, equals(false));
      expect(restoredSites[0].userAgent, equals('Custom/1.0'));
      expect(restoredSites[0].thirdPartyCookiesEnabled, equals(true));
      expect(restoredSites[0].proxySettings.type, equals(ProxyType.HTTP));
      expect(restoredSites[0].proxySettings.address, equals('proxy:8080'));

      // Verify webspaces
      expect(restoredWebspaces, hasLength(2));
      expect(restoredWebspaces[0].id, equals(kAllWebspaceId));
      expect(restoredWebspaces[1].id, equals('work'));
      expect(restoredWebspaces[1].name, equals('Work'));

      // Verify settings
      expect(importedBackup.themeMode, equals(2));
      expect(importedBackup.showUrlBar, equals(true));
      expect(importedBackup.selectedWebspaceId, equals('work'));
      expect(importedBackup.currentIndex, equals(0));
    });

    test('should handle multiple export/import cycles', () {
      // First cycle
      final sites1 = [WebViewModel(initUrl: 'https://first.com')];
      final backup1 = SettingsBackupService.createBackup(
        webViewModels: sites1,
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );
      final json1 = SettingsBackupService.exportToJson(backup1);

      // Import first backup
      final imported1 = SettingsBackupService.importFromJson(json1)!;
      final restored1 = SettingsBackupService.restoreSites(imported1, null);

      // Add more sites
      restored1.add(WebViewModel(initUrl: 'https://second.com'));

      // Second cycle with modified data
      final backup2 = SettingsBackupService.createBackup(
        webViewModels: restored1,
        webspaces: [Webspace.all(), Webspace(name: 'New')],
        themeMode: 1,
        showUrlBar: true,
      );
      final json2 = SettingsBackupService.exportToJson(backup2);

      // Import second backup
      final imported2 = SettingsBackupService.importFromJson(json2)!;
      final restored2 = SettingsBackupService.restoreSites(imported2, null);
      final restoredWs2 = SettingsBackupService.restoreWebspaces(imported2);

      // Verify final state
      expect(restored2, hasLength(2));
      expect(restored2[0].initUrl, equals('https://first.com'));
      expect(restored2[1].initUrl, equals('https://second.com'));
      expect(restoredWs2, hasLength(2)); // All + New
      expect(imported2.themeMode, equals(1));
      expect(imported2.showUrlBar, equals(true));
    });

    test('proxy passwords never appear in exports (PWD-005)', () {
      // Per `proxy-password-secure-storage` spec PWD-005, the export
      // format is uniformly password-less. This is the regression guard
      // — if a future contributor reintroduces an `includePassword`-style
      // flag and toggles it on for the backup path, this test fails
      // loudly. The substring check covers any encoding (`"password":`,
      // base64, raw, etc.) since the actual password value is unique.
      const perSitePwd = 'per-site-needle-7f3a';
      const globalPwd = 'global-needle-c421';
      final sites = [
        WebViewModel(
          initUrl: 'https://a.com',
          proxySettings: UserProxySettings(
            type: ProxyType.HTTP,
            address: 'p:8080',
            username: 'u1',
            password: perSitePwd,
          ),
        ),
      ];
      // Mimic what `_exportSettings` would pass: globalPrefs holds a
      // JSON-encoded UserProxySettings under kGlobalOutboundProxyKey.
      // The whole point of PWD-005 is that even if a buggy caller
      // happened to slip a password into that JSON, the export must not
      // forward it — but we also assert the canonical case where prefs
      // are already sanitised and the value is password-less.
      final globalProxy = UserProxySettings(
        type: ProxyType.HTTP,
        address: 'g:3128',
        username: 'g1',
        password: globalPwd,
      );
      final backup = SettingsBackupService.createBackup(
        webViewModels: sites,
        webspaces: [Webspace.all()],
        themeMode: 0,
        // Sanitised globalPrefs (the way _exportSettings actually feeds
        // it) — globalProxy.toJson() is password-less by contract.
        globalPrefs: <String, Object?>{
          kGlobalOutboundProxyKey: jsonEncode(globalProxy.toJson()),
        },
      );
      final exported = SettingsBackupService.exportToJson(backup);
      expect(exported.contains(perSitePwd), isFalse,
          reason: 'per-site proxy password leaked into exported JSON');
      expect(exported.contains(globalPwd), isFalse,
          reason: 'global proxy password leaked into exported JSON');
    });

    test('secure cookies never appear in export, non-secure cookies preserved', () {
      // Create site with mixed cookies
      final siteWithCookies = WebViewModel(
        initUrl: 'https://example.com',
        cookies: [
          Cookie(name: 'session', value: 'secret', isSecure: true),
          Cookie(name: 'theme', value: 'dark', isSecure: false),
        ],
      );

      // First export (secure cookies stripped, non-secure preserved)
      final backup1 = SettingsBackupService.createBackup(
        webViewModels: [siteWithCookies],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final cookies1 = backup1.sites[0]['cookies'] as List;
      expect(cookies1, hasLength(1));
      expect(cookies1[0]['name'], equals('theme'));

      // Import
      final json1 = SettingsBackupService.exportToJson(backup1);
      final imported1 = SettingsBackupService.importFromJson(json1)!;
      final restored1 = SettingsBackupService.restoreSites(imported1, null);

      expect(restored1[0].cookies, hasLength(1));
      expect(restored1[0].cookies[0].name, equals('theme'));

      // Second export of restored data
      final backup2 = SettingsBackupService.createBackup(
        webViewModels: restored1,
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final cookies2 = backup2.sites[0]['cookies'] as List;
      expect(cookies2, hasLength(1));
      expect(cookies2[0]['name'], equals('theme'));
    });
  });

  group('Global prefs registry', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('every registered key round-trips through export and import', () async {
      // Write a non-default value for every registered key.
      final prefs = await SharedPreferences.getInstance();
      final nonDefaults = <String, Object>{};
      for (final entry in kExportedAppPrefs.entries) {
        final key = entry.key;
        final defaultValue = entry.value;
        late Object override;
        if (defaultValue is bool) {
          override = !defaultValue;
          await prefs.setBool(key, override as bool);
        } else if (defaultValue is int) {
          override = defaultValue + 7;
          await prefs.setInt(key, override as int);
        } else if (defaultValue is double) {
          override = defaultValue + 0.5;
          await prefs.setDouble(key, override as double);
        } else if (defaultValue is String) {
          override = 'override-$key';
          await prefs.setString(key, override as String);
        } else if (defaultValue is List<String>) {
          override = <String>['override-$key'];
          await prefs.setStringList(key, override as List<String>);
        } else {
          fail('Add a test case for type ${defaultValue.runtimeType}');
        }
        nonDefaults[key] = override;
      }

      // Export using the registry reader.
      final backup = SettingsBackupService.createBackup(
        webViewModels: [],
        webspaces: [Webspace.all()],
        themeMode: 0,
        globalPrefs: readExportedAppPrefs(prefs),
      );

      // Every registered key must appear in the backup's globalPrefs with the
      // non-default value. If this fails after adding a new pref, it means
      // the registry is not being read correctly during export.
      for (final key in kExportedAppPrefs.keys) {
        expect(
          backup.globalPrefs[key],
          equals(nonDefaults[key]),
          reason:
              'Registered pref "$key" was not captured during export. '
              'Ensure kExportedAppPrefs in lib/settings/app_prefs.dart '
              'includes it and readExportedAppPrefs understands its type.',
        );
      }

      // Simulate a fresh install.
      SharedPreferences.setMockInitialValues({});
      final freshPrefs = await SharedPreferences.getInstance();
      for (final key in kExportedAppPrefs.keys) {
        expect(freshPrefs.get(key), isNull);
      }

      // Apply the backup and assert each key was restored to the non-default
      // value. A missing restore path for a new pref will fail here.
      await writeExportedAppPrefs(freshPrefs, backup.globalPrefs);
      for (final key in kExportedAppPrefs.keys) {
        expect(
          freshPrefs.get(key),
          equals(nonDefaults[key]),
          reason:
              'Registered pref "$key" was not restored during import. '
              'Ensure writeExportedAppPrefs handles its type.',
        );
      }
    });

    test('round-trips through JSON string without loss', () async {
      final prefs = await SharedPreferences.getInstance();
      // Flip every boolean pref to a non-default value for coverage.
      for (final entry in kExportedAppPrefs.entries) {
        if (entry.value is bool) {
          await prefs.setBool(entry.key, !(entry.value as bool));
        }
      }

      final backup = SettingsBackupService.createBackup(
        webViewModels: [],
        webspaces: [Webspace.all()],
        themeMode: 0,
        globalPrefs: readExportedAppPrefs(prefs),
      );
      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;

      for (final entry in kExportedAppPrefs.entries) {
        expect(
          imported.globalPrefs[entry.key],
          equals(backup.globalPrefs[entry.key]),
          reason: 'Key "${entry.key}" lost across JSON round-trip',
        );
      }
    });

    test('legacy top-level fields migrate into globalPrefs', () {
      // Older backup files stored these as flat top-level keys. The
      // fromJson migration must preserve the values under globalPrefs so
      // existing user backups still import correctly.
      final legacyJson = {
        'version': 1,
        'sites': [],
        'webspaces': [],
        'themeMode': 0,
        'showUrlBar': true,
        'showTabStrip': true,
        'showStatsBanner': false,
        'exportedAt': '2024-01-01T00:00:00.000',
      };
      final backup = SettingsBackup.fromJson(legacyJson);
      expect(backup.globalPrefs['showUrlBar'], equals(true));
      expect(backup.globalPrefs['showTabStrip'], equals(true));
      expect(backup.globalPrefs['showStatsBanner'], equals(false));
      expect(backup.showUrlBar, equals(true));
      expect(backup.showTabStrip, equals(true));
      expect(backup.showStatsBanner, equals(false));
    });
  });

  group('Edge Cases', () {
    test('should handle sites with special characters in names', () {
      final site = WebViewModel(
        initUrl: 'https://example.com',
        name: 'Test!@#\$%^&*()_+-=[]{}|;:\'",.<>?/`~',
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: [site],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;
      final restored = SettingsBackupService.restoreSites(imported, null);

      expect(restored[0].name, equals(site.name));
    });

    test('should handle sites with unicode characters', () {
      final site = WebViewModel(
        initUrl: 'https://example.com',
        name: '工作站 🚀 Espace de travail',
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: [site],
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;
      final restored = SettingsBackupService.restoreSites(imported, null);

      expect(restored[0].name, equals('工作站 🚀 Espace de travail'));
    });

    test('should handle large number of sites', () {
      final sites = List.generate(
        100,
        (i) => WebViewModel(initUrl: 'https://site$i.com', name: 'Site $i'),
      );

      final backup = SettingsBackupService.createBackup(
        webViewModels: sites,
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      expect(backup.sites, hasLength(100));

      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;
      final restored = SettingsBackupService.restoreSites(imported, null);

      expect(restored, hasLength(100));
      expect(restored[99].initUrl, equals('https://site99.com'));
    });

    test('should handle large number of webspaces', () {
      final webspaces = [
        Webspace.all(),
        ...List.generate(50, (i) => Webspace(name: 'Workspace $i')),
      ];

      final backup = SettingsBackupService.createBackup(
        webViewModels: [],
        webspaces: webspaces,
        themeMode: 0,
        showUrlBar: false,
      );

      // 50 custom webspaces (All excluded)
      expect(backup.webspaces, hasLength(50));

      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;
      final restored = SettingsBackupService.restoreWebspaces(imported);

      // All + 50 custom
      expect(restored, hasLength(51));
    });

    test('should handle sites with all proxy types', () {
      final sites = [
        WebViewModel(
          initUrl: 'https://default.com',
          proxySettings: UserProxySettings(type: ProxyType.DEFAULT),
        ),
        WebViewModel(
          initUrl: 'https://http.com',
          proxySettings: UserProxySettings(type: ProxyType.HTTP, address: 'http:8080'),
        ),
        WebViewModel(
          initUrl: 'https://https.com',
          proxySettings: UserProxySettings(type: ProxyType.HTTPS, address: 'https:443'),
        ),
        WebViewModel(
          initUrl: 'https://socks.com',
          proxySettings: UserProxySettings(type: ProxyType.SOCKS5, address: 'socks:1080'),
        ),
      ];

      final backup = SettingsBackupService.createBackup(
        webViewModels: sites,
        webspaces: [Webspace.all()],
        themeMode: 0,
        showUrlBar: false,
      );

      final jsonString = SettingsBackupService.exportToJson(backup);
      final imported = SettingsBackupService.importFromJson(jsonString)!;
      final restored = SettingsBackupService.restoreSites(imported, null);

      expect(restored[0].proxySettings.type, equals(ProxyType.DEFAULT));
      expect(restored[1].proxySettings.type, equals(ProxyType.HTTP));
      expect(restored[2].proxySettings.type, equals(ProxyType.HTTPS));
      expect(restored[3].proxySettings.type, equals(ProxyType.SOCKS5));
      expect(restored[3].proxySettings.address, equals('socks:1080'));
    });
  });
}
