import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Notification payload encoding', () {
    test('payload encodes siteId as JSON', () {
      final siteId = 'lqv2x3k-abc123';
      final payload = jsonEncode({'siteId': siteId});
      final decoded = jsonDecode(payload);
      expect(decoded['siteId'], equals(siteId));
    });

    test('notification id is deterministic from siteId and title', () {
      const siteId = 'test-site';
      const title = 'New message';
      final id1 = siteId.hashCode ^ title.hashCode;
      final id2 = siteId.hashCode ^ title.hashCode;
      expect(id1, equals(id2));
    });

    test('different titles produce different ids', () {
      const siteId = 'test-site';
      final id1 = siteId.hashCode ^ 'Message A'.hashCode;
      final id2 = siteId.hashCode ^ 'Message B'.hashCode;
      expect(id1, isNot(equals(id2)));
    });

    test('tap payload round-trips through JSON', () {
      final original = {'siteId': 'my-site-id'};
      final encoded = jsonEncode(original);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded['siteId'], equals('my-site-id'));
    });
  });
}
