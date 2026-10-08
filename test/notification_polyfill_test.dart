import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';

void main() {
  group('Notification polyfill script', () {
    test('granted permission when notificationsEnabled is true', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'abc123',
        notificationsEnabled: true,
      );
      expect(script, contains('"notificationsEnabled":true'));
      expect(script, contains('"siteId":"abc123"'));
    });

    test('covers page-context ServiceWorkerRegistration.showNotification', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'sw1',
        notificationsEnabled: true,
      );
      expect(script,
          contains('ServiceWorkerRegistration.prototype.showNotification'));
      expect(script, contains("callHandler('webNotification'"));
    });

    test('emits a console breadcrumb when a notification is suppressed', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'sw2',
        notificationsEnabled: false,
      );
      expect(script, contains('suppressed: permission'));
      expect(script, contains("blocked('Notification'"));
      expect(script, contains("blocked('showNotification'"));
    });

    test('denied permission when notificationsEnabled is false', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'xyz789',
        notificationsEnabled: false,
      );
      expect(script, contains('"notificationsEnabled":false'));
      expect(script, contains('"siteId":"xyz789"'));
    });

    test('a siteId is embedded as a JS string literal', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'a"b\\c',
        notificationsEnabled: true,
      );
      expect(script, contains(r'"siteId":"a\"b\\c"'));
    });

    test('script defines window.Notification', () {
      final script = buildNotificationPolyfillShim(
        siteId: 'test',
        notificationsEnabled: true,
      );
      expect(script, contains("Object.defineProperty(window, 'Notification'"));
      expect(script, contains('Notification.requestPermission'));
      expect(script, contains('Notification.permission'));
    });
  });
}
