import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/notification_polyfill_shim.dart';

void main() {
  group('Notification polyfill script', () {
    test('NOTIF-010: the config carries no site id into the frames it runs in', () {
      for (final enabled in [true, false]) {
        expect(buildNotificationPolyfillShim(notificationsEnabled: enabled),
            isNot(contains('siteId')));
      }
    });

    test('granted permission when notificationsEnabled is true', () {
      final script = buildNotificationPolyfillShim(notificationsEnabled: true);
      expect(script, contains('"notificationsEnabled":true'));
    });

    test('covers page-context ServiceWorkerRegistration.showNotification', () {
      final script = buildNotificationPolyfillShim(notificationsEnabled: true);
      expect(script,
          contains('ServiceWorkerRegistration.prototype.showNotification'));
      expect(script, contains("callHandler('webNotification'"));
    });

    test('emits a console breadcrumb when a notification is suppressed', () {
      final script = buildNotificationPolyfillShim(notificationsEnabled: false);
      expect(script, contains('suppressed: permission'));
      expect(script, contains("blocked('Notification'"));
      expect(script, contains("blocked('showNotification'"));
    });

    test('denied permission when notificationsEnabled is false', () {
      final script = buildNotificationPolyfillShim(notificationsEnabled: false);
      expect(script, contains('"notificationsEnabled":false'));
    });

    test('script defines window.Notification', () {
      final script = buildNotificationPolyfillShim(notificationsEnabled: true);
      expect(script, contains("Object.defineProperty(window, 'Notification'"));
      expect(script, contains('Notification.requestPermission'));
      expect(script, contains('Notification.permission'));
    });
  });
}
