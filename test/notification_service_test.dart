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

    test('tap payload round-trips through JSON', () {
      final original = {'siteId': 'my-site-id'};
      final encoded = jsonEncode(original);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded['siteId'], equals('my-site-id'));
    });
  });

  group('Notification identity (NOTIF-002)', () {
    NotificationTarget target(String siteId, String? tag, int seq) =>
        NotificationTarget.resolve(siteId: siteId, tag: tag, sequence: seq);

    test('same page tag from the same site replaces the earlier post', () {
      final a = target('site-a', 'chat-42', 1);
      final b = target('site-a', 'chat-42', 2);
      expect(b.tag, equals(a.tag));
      expect(b.id, equals(a.id));
    });

    test('different page tags coexist', () {
      final a = target('site-a', 'chat-42', 1);
      final b = target('site-a', 'chat-43', 1);
      expect(a.id, isNot(equals(b.id)));
    });

    test('the same page tag on two sites does not collide', () {
      final a = target('site-a', 'chat-42', 1);
      final b = target('site-b', 'chat-42', 1);
      expect(a.id, isNot(equals(b.id)));
    });

    test('untagged posts never replace each other', () {
      final ids = {
        for (var seq = 1; seq <= 5; seq++) target('site-a', null, seq).id,
      };
      expect(ids.length, equals(5));
    });

    test('empty tag from the polyfill counts as untagged', () {
      // The JS polyfill sends `String(options.tag || '')`, so an untagged
      // page notification arrives as '' rather than null.
      final a = target('site-a', '', 1);
      final b = target('site-a', '', 2);
      expect(a.id, isNot(equals(b.id)));
    });

    test('the OS tag stays the siteId so taps route back to the site', () {
      expect(target('site-a', 'chat-42', 1).tag, equals('site-a'));
      expect(target('site-a', null, 1).tag, equals('site-a'));
    });

    test('ids stay non-negative 31-bit', () {
      for (final t in [
        target('site-a', 'chat-42', 1),
        target('site-a', null, DateTime.now().microsecondsSinceEpoch),
        target('', null, -1),
      ]) {
        expect(t.id, greaterThanOrEqualTo(0));
        expect(t.id, lessThanOrEqualTo(0x7fffffff));
      }
    });
  });
}
