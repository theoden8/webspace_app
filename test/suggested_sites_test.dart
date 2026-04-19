import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show SiteSuggestion;
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/suggested_sites_service.dart';

void main() {
  group('SiteSuggestion', () {
    test('should store name, url, and domain', () {
      const s = SiteSuggestion(
        name: 'GitHub',
        url: 'https://github.com',
        domain: 'github.com',
      );
      expect(s.name, 'GitHub');
      expect(s.url, 'https://github.com');
      expect(s.domain, 'github.com');
    });
  });

  group('kDefaultSuggestions', () {
    test('should contain expected sites', () {
      expect(kDefaultSuggestions, isNotEmpty);
      expect(kDefaultSuggestions.length, 21);

      final names = kDefaultSuggestions.map((s) => s.name).toList();
      expect(names, contains('Duck.ai'));
      expect(names, contains('GitHub'));
      expect(names, contains('Claude'));
      expect(names, isNot(contains('DuckDuckGo')));
    });

    test('all entries should have valid URLs', () {
      for (final s in kDefaultSuggestions) {
        expect(s.name, isNotEmpty);
        expect(s.url, startsWith('https://'));
        expect(s.domain, isNotEmpty);
        final uri = Uri.parse(s.url);
        expect(uri.host, isNotEmpty);
      }
    });
  });

  group('Flavor detection', () {
    // In test environment, FLUTTER_APP_FLAVOR is not set,
    // so isFdroidFlavor should be false.
    test('isFdroidFlavor is false when FLUTTER_APP_FLAVOR is not set', () {
      expect(isFdroidFlavor, isFalse);
    });

    test('flavorDefaultSuggestions returns full list when not fdroid', () {
      expect(flavorDefaultSuggestions, equals(kDefaultSuggestions));
      expect(flavorDefaultSuggestions, isNotEmpty);
    });
  });

  group('Persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('loadSuggestedSites returns null when no customization saved', () async {
      final result = await loadSuggestedSites();
      expect(result, isNull);
    });

    test('saveSuggestedSites and loadSuggestedSites round-trip', () async {
      final sites = [
        const SiteSuggestion(name: 'Test', url: 'https://test.com', domain: 'test.com'),
        const SiteSuggestion(name: 'Example', url: 'https://example.org', domain: 'example.org'),
      ];

      await saveSuggestedSites(sites);
      final loaded = await loadSuggestedSites();

      expect(loaded, isNotNull);
      expect(loaded!.length, 2);
      expect(loaded[0].name, 'Test');
      expect(loaded[0].url, 'https://test.com');
      expect(loaded[0].domain, 'test.com');
      expect(loaded[1].name, 'Example');
      expect(loaded[1].url, 'https://example.org');
      expect(loaded[1].domain, 'example.org');
    });

    test('saveSuggestedSites with empty list persists empty list', () async {
      await saveSuggestedSites([]);
      final loaded = await loadSuggestedSites();

      expect(loaded, isNotNull);
      expect(loaded, isEmpty);
    });

    test('resetSuggestedSites removes customization', () async {
      final sites = [
        const SiteSuggestion(name: 'Test', url: 'https://test.com', domain: 'test.com'),
      ];

      await saveSuggestedSites(sites);
      expect(await loadSuggestedSites(), isNotNull);

      await resetSuggestedSites();
      expect(await loadSuggestedSites(), isNull);
    });

    test('loadSuggestedSites returns null on corrupted JSON', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('suggested_sites', 'not valid json');

      final result = await loadSuggestedSites();
      expect(result, isNull);
    });

    test('loadSuggestedSites returns null on wrong JSON structure', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('suggested_sites', '{"foo": "bar"}');

      final result = await loadSuggestedSites();
      expect(result, isNull);
    });
  });

  group('getEffectiveSuggestedSites', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('returns flavor defaults when no customization', () async {
      final result = await getEffectiveSuggestedSites();
      // In test env, flavor is not fdroid, so we get full defaults
      expect(result, equals(kDefaultSuggestions));
    });

    test('returns custom list when customization saved', () async {
      final custom = [
        const SiteSuggestion(name: 'Custom', url: 'https://custom.io', domain: 'custom.io'),
      ];
      await saveSuggestedSites(custom);

      final result = await getEffectiveSuggestedSites();
      expect(result.length, 1);
      expect(result[0].name, 'Custom');
    });

    test('returns empty list when empty customization saved', () async {
      await saveSuggestedSites([]);

      final result = await getEffectiveSuggestedSites();
      expect(result, isEmpty);
    });

    test('returns defaults after reset', () async {
      await saveSuggestedSites([
        const SiteSuggestion(name: 'Temp', url: 'https://temp.com', domain: 'temp.com'),
      ]);
      await resetSuggestedSites();

      final result = await getEffectiveSuggestedSites();
      expect(result, equals(kDefaultSuggestions));
    });
  });

  group('JSON serialization', () {
    test('serialized format matches expected structure', () async {
      SharedPreferences.setMockInitialValues({});

      final sites = [
        const SiteSuggestion(name: 'GitHub', url: 'https://github.com', domain: 'github.com'),
      ];
      await saveSuggestedSites(sites);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('suggested_sites')!;
      final parsed = jsonDecode(raw) as List<dynamic>;

      expect(parsed.length, 1);
      expect(parsed[0]['name'], 'GitHub');
      expect(parsed[0]['url'], 'https://github.com');
      expect(parsed[0]['domain'], 'github.com');
    });

    test('handles many sites', () async {
      SharedPreferences.setMockInitialValues({});

      await saveSuggestedSites(kDefaultSuggestions);
      final loaded = await loadSuggestedSites();

      expect(loaded, isNotNull);
      expect(loaded!.length, kDefaultSuggestions.length);
      for (var i = 0; i < kDefaultSuggestions.length; i++) {
        expect(loaded[i].name, kDefaultSuggestions[i].name);
        expect(loaded[i].url, kDefaultSuggestions[i].url);
        expect(loaded[i].domain, kDefaultSuggestions[i].domain);
      }
    });
  });

  group('SettingsBackup suggestedSites integration', () {
    test('backup with suggestedSites serializes correctly', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime(2026, 3, 28),
        suggestedSites: [
          {'name': 'Test', 'url': 'https://test.com', 'domain': 'test.com'},
        ],
      );

      final json = backup.toJson();
      expect(json['suggestedSites'], isNotNull);
      expect((json['suggestedSites'] as List).length, 1);
      expect((json['suggestedSites'] as List)[0]['name'], 'Test');
    });

    test('backup without suggestedSites omits the field', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [],
        themeMode: 0,
        showUrlBar: false,
        exportedAt: DateTime(2026, 3, 28),
      );

      final json = backup.toJson();
      expect(json.containsKey('suggestedSites'), isFalse);
    });

    test('fromJson parses suggestedSites', () {
      final json = {
        'sites': [],
        'webspaces': [],
        'suggestedSites': [
          {'name': 'A', 'url': 'https://a.com', 'domain': 'a.com'},
          {'name': 'B', 'url': 'https://b.com', 'domain': 'b.com'},
        ],
      };

      final backup = SettingsBackup.fromJson(json);
      expect(backup.suggestedSites, isNotNull);
      expect(backup.suggestedSites!.length, 2);
      expect(backup.suggestedSites![0]['name'], 'A');
      expect(backup.suggestedSites![1]['name'], 'B');
    });

    test('fromJson handles missing suggestedSites (backward compat)', () {
      final json = {
        'sites': [],
        'webspaces': [],
      };

      final backup = SettingsBackup.fromJson(json);
      expect(backup.suggestedSites, isNull);
    });

    test('round-trip preserves suggestedSites', () {
      final original = SettingsBackup(
        version: 1,
        sites: [],
        webspaces: [],
        themeMode: 2,
        showUrlBar: true,
        exportedAt: DateTime(2026, 3, 28),
        suggestedSites: [
          {'name': 'GitHub', 'url': 'https://github.com', 'domain': 'github.com'},
        ],
      );

      final jsonString = jsonEncode(original.toJson());
      final restored = SettingsBackup.fromJson(jsonDecode(jsonString));

      expect(restored.suggestedSites, isNotNull);
      expect(restored.suggestedSites!.length, 1);
      expect(restored.suggestedSites![0]['name'], 'GitHub');
    });
  });
}
