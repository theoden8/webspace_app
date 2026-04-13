import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/content_blocker_service.dart';

void main() {
  group('FilterList', () {
    test('serializes to JSON correctly', () {
      final list = FilterList(
        id: 'test-list',
        name: 'Test List',
        url: 'https://example.com/list.txt',
        enabled: true,
        lastUpdated: DateTime(2024, 1, 15, 10, 30),
        ruleCount: 1000,
        skippedCount: 50,
      );

      final json = list.toJson();

      expect(json['id'], equals('test-list'));
      expect(json['name'], equals('Test List'));
      expect(json['url'], equals('https://example.com/list.txt'));
      expect(json['enabled'], isTrue);
      expect(json['lastUpdated'], isNotNull);
      expect(json['ruleCount'], equals(1000));
      expect(json['skippedCount'], equals(50));
    });

    test('deserializes from JSON correctly', () {
      final json = {
        'id': 'test-list',
        'name': 'Test List',
        'url': 'https://example.com/list.txt',
        'enabled': true,
        'lastUpdated': '2024-01-15T10:30:00.000',
        'ruleCount': 1000,
        'skippedCount': 50,
      };

      final list = FilterList.fromJson(json);

      expect(list.id, equals('test-list'));
      expect(list.name, equals('Test List'));
      expect(list.url, equals('https://example.com/list.txt'));
      expect(list.enabled, isTrue);
      expect(list.lastUpdated, isNotNull);
      expect(list.ruleCount, equals(1000));
      expect(list.skippedCount, equals(50));
    });

    test('handles missing optional fields in JSON', () {
      final json = {
        'id': 'test',
        'name': 'Test',
        'url': 'https://example.com/list.txt',
      };

      final list = FilterList.fromJson(json);

      expect(list.enabled, isFalse);
      expect(list.lastUpdated, isNull);
      expect(list.ruleCount, equals(0));
      expect(list.skippedCount, equals(0));
    });

    test('round-trips through JSON correctly', () {
      final original = FilterList(
        id: 'roundtrip',
        name: 'Round Trip',
        url: 'https://example.com/rules.txt',
        enabled: true,
        lastUpdated: DateTime(2024, 6, 1),
        ruleCount: 5000,
        skippedCount: 200,
      );

      final json = original.toJson();
      final restored = FilterList.fromJson(json);

      expect(restored.id, equals(original.id));
      expect(restored.name, equals(original.name));
      expect(restored.url, equals(original.url));
      expect(restored.enabled, equals(original.enabled));
      expect(restored.ruleCount, equals(original.ruleCount));
      expect(restored.skippedCount, equals(original.skippedCount));
    });

    test('serializes list of FilterLists to JSON string', () {
      final lists = [
        FilterList(id: 'a', name: 'List A', url: 'https://a.com/list.txt'),
        FilterList(
            id: 'b',
            name: 'List B',
            url: 'https://b.com/list.txt',
            enabled: true,
            ruleCount: 100),
      ];

      final jsonStr = jsonEncode(lists.map((l) => l.toJson()).toList());
      final decoded = jsonDecode(jsonStr) as List;

      expect(decoded.length, equals(2));
      final restored = decoded
          .map((e) => FilterList.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      expect(restored[0].id, equals('a'));
      expect(restored[1].enabled, isTrue);
      expect(restored[1].ruleCount, equals(100));
    });
  });

  group('ContentBlockerService', () {
    test('instance is a singleton', () {
      final a = ContentBlockerService.instance;
      final b = ContentBlockerService.instance;
      expect(identical(a, b), isTrue);
    });

    test('hasRules returns false when no rules loaded', () {
      final service = ContentBlockerService.instance;
      service.reset();
      expect(service.hasRules, isFalse);
    });

    test('totalRuleCount sums enabled lists', () {
      final service = ContentBlockerService.instance;
      service.reset();
      service.setLists([
        FilterList(
          id: 'a',
          name: 'A',
          url: 'https://a.com',
          enabled: true,
          ruleCount: 100,
        ),
        FilterList(
          id: 'b',
          name: 'B',
          url: 'https://b.com',
          enabled: false,
          ruleCount: 200,
        ),
        FilterList(
          id: 'c',
          name: 'C',
          url: 'https://c.com',
          enabled: true,
          ruleCount: 300,
        ),
      ]);
      expect(service.totalRuleCount, equals(400));
    });

    test('lists getter returns unmodifiable list', () {
      final service = ContentBlockerService.instance;
      service.reset();
      service.setLists([
        FilterList(id: 'x', name: 'X', url: 'https://x.com'),
      ]);
      expect(() => service.lists.add(FilterList(id: 'y', name: 'Y', url: 'https://y.com')),
          throwsUnsupportedError);
    });

    test('isBlocked checks domain and parent domains', () {
      final service = ContentBlockerService.instance;
      service.reset();
      service.setBlockedDomains({'tracker.net', 'ads.example.com'});

      expect(service.isBlocked('https://tracker.net/path'), isTrue);
      expect(service.isBlocked('https://sub.tracker.net/path'), isTrue);
      expect(service.isBlocked('https://ads.example.com/script.js'), isTrue);
      expect(service.isBlocked('https://example.com'), isFalse);
      expect(service.isBlocked('https://mytracker.net'), isFalse);
    });

    test('isBlocked respects exception domains', () {
      final service = ContentBlockerService.instance;
      service.reset();
      service.setBlockedDomains({'tracker.net', 'ads.example.com'});
      service.setExceptionDomains({'cdn.tracker.net'});

      // tracker.net is blocked
      expect(service.isBlocked('https://tracker.net/path'), isTrue);
      // cdn.tracker.net is excepted — should NOT be blocked
      expect(service.isBlocked('https://cdn.tracker.net/resource.js'), isFalse);
      // sub.cdn.tracker.net is also excepted (parent domain walk-up)
      expect(service.isBlocked('https://sub.cdn.tracker.net/resource.js'), isFalse);
      // other subdomain still blocked
      expect(service.isBlocked('https://other.tracker.net/path'), isTrue);
    });

    test('isBlocked with exception on exact blocked domain', () {
      final service = ContentBlockerService.instance;
      service.reset();
      service.setBlockedDomains({'example.com'});
      service.setExceptionDomains({'example.com'});

      // Exception overrides block for exact match
      expect(service.isBlocked('https://example.com'), isFalse);
      expect(service.isBlocked('https://sub.example.com'), isFalse);
    });

    test('getCosmeticScript returns null when no selectors', () {
      final service = ContentBlockerService.instance;
      service.reset();
      expect(service.getCosmeticScript('https://example.com'), isNull);
    });
  });
}
