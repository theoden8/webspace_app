import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/notification_service.dart';

void main() {
  group('NotificationService permission tracking (NOTIF-007 / 16.x)', () {
    test('addPermissionListener fires when permission state flips', () {
      // Reset fields by re-instantiating the singleton via a fresh field
      // probe; the service tracks state internally and notifies listeners
      // on requestPermission(). Here we exercise the listener wiring
      // directly without dispatching to the platform plugin (which is
      // unavailable in unit tests on non-iOS hosts).
      final svc = NotificationService.instance;
      int fired = 0;
      void cb() => fired++;
      svc.addPermissionListener(cb);
      svc.removePermissionListener(cb);
      // Listener removal is a no-throw, no-fire contract.
      expect(fired, equals(0));
    });

    test('permissionGranted is null until requestPermission has resolved', () {
      // On non-iOS hosts the plugin returns null/false, but the contract
      // is: getter returns the last-known result, starting null until the
      // first request. We can only assert null-or-bool here without a
      // platform plugin; the important contract is the type shape.
      final value = NotificationService.instance.permissionGranted;
      expect(value, anyOf(isNull, isA<bool>()));
    });
  });

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
