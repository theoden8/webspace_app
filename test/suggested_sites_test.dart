import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/add_site.dart';
import 'package:webspace/settings/site_suggestion.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/suggested_sites_service.dart';

import 'helpers/localized.dart';

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

  group('Persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('a fresh install has no suggested sites (SUGGEST-001)', () async {
      expect(await loadSuggestedSites(), isEmpty);
    });

    testWidgets('a fresh install shows the empty suggestions grid (SUGGEST-001)',
        (tester) async {
      final suggestions = await tester.runAsync(loadSuggestedSites);
      await pumpLocalized(
        tester,
        home: AddSiteScreen(
          suggestions: suggestions!,
          onSuggestionsChanged: (_) {},
        ),
      );
      await tester.pump();

      final loc = AppLocalizations.of(tester.element(find.byType(AddSiteScreen)));
      expect(find.text(loc.addSiteNoSuggestions), findsOneWidget);
      expect(find.byTooltip(loc.addSiteAddSuggestedTooltip), findsOneWidget);
    });

    test('saveSuggestedSites and loadSuggestedSites round-trip (SUGGEST-004)', () async {
      final sites = [
        const SiteSuggestion(name: 'Test', url: 'https://test.com', domain: 'test.com'),
        const SiteSuggestion(name: 'Example', url: 'https://example.org', domain: 'example.org'),
      ];

      await saveSuggestedSites(sites);
      final loaded = await loadSuggestedSites();

      expect(loaded.length, 2);
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

      expect(loaded, isEmpty);
    });

    test('loadSuggestedSites returns none on corrupted JSON', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('suggested_sites', 'not valid json');

      expect(await loadSuggestedSites(), isEmpty);
    });

    test('loadSuggestedSites returns none on wrong JSON structure', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('suggested_sites', '{"foo": "bar"}');

      expect(await loadSuggestedSites(), isEmpty);
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

      final sites = [
        for (var i = 0; i < 30; i++)
          SiteSuggestion(
            name: 'Site $i',
            url: 'https://site$i.example',
            domain: 'site$i.example',
          ),
      ];
      await saveSuggestedSites(sites);
      final loaded = await loadSuggestedSites();

      expect(loaded.length, sites.length);
      for (var i = 0; i < sites.length; i++) {
        expect(loaded[i].name, sites[i].name);
        expect(loaded[i].url, sites[i].url);
        expect(loaded[i].domain, sites[i].domain);
      }
    });
  });

  group('SettingsBackup suggestedSites integration (SUGGEST-005)', () {
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
