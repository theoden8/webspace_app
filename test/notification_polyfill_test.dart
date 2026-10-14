import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';

void main() {
  group('Notification polyfill script', () {
    test('granted permission when notificationsEnabled is true', () {
      final script = buildNotificationPolyfillShim(
        siteId: SiteId('abc123'),
        notificationsEnabled: true,
      );
      expect(script, contains('"notificationsEnabled":true'));
      expect(script, contains('"siteId":"abc123"'));
    });

    test('covers page-context ServiceWorkerRegistration.showNotification', () {
      final script = buildNotificationPolyfillShim(
        siteId: SiteId('sw1'),
        notificationsEnabled: true,
      );
      expect(script,
          contains('ServiceWorkerRegistration.prototype.showNotification'));
      expect(script, contains("callHandler('webNotification'"));
    });

    test('emits a console breadcrumb when a notification is suppressed', () {
      final script = buildNotificationPolyfillShim(
        siteId: SiteId('sw2'),
        notificationsEnabled: false,
      );
      expect(script, contains('suppressed: permission'));
      expect(script, contains("blocked('Notification'"));
      expect(script, contains("blocked('showNotification'"));
    });

    test('denied permission when notificationsEnabled is false', () {
      final script = buildNotificationPolyfillShim(
        siteId: SiteId('xyz789'),
        notificationsEnabled: false,
      );
      expect(script, contains('"notificationsEnabled":false'));
      expect(script, contains('"siteId":"xyz789"'));
    });

    test('script defines window.Notification', () {
      final script = buildNotificationPolyfillShim(
        siteId: SiteId('test'),
        notificationsEnabled: true,
      );
      expect(script, contains("Object.defineProperty(window, 'Notification'"));
      expect(script, contains('Notification.requestPermission'));
      expect(script, contains('Notification.permission'));
    });
  });
}
