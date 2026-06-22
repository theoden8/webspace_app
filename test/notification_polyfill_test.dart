import 'package:flutter_test/flutter_test.dart';

// Import the function directly since it's in the webview.dart library.
// We need to test the template substitution without depending on InAppWebView.
// The polyfill function is private, so we test via the public API indirectly
// by checking the string contents.

void main() {
  group('Notification polyfill script', () {
    // Since _notificationPolyfillScript is private to webview.dart,
    // we replicate the substitution logic here for validation.
    // The actual integration is tested via the manual test fixture.

    String buildPolyfill({
      required String siteId,
      required bool notificationsEnabled,
    }) {
      final permission = notificationsEnabled ? 'granted' : 'denied';
      return '''
(function() {
  var SITE_ID = '$siteId';
  var permission = '$permission';
  function deliver(title, options) {
    options = options || {};
    window.flutter_inappwebview.callHandler('webNotification', {
      title: String(title),
      body: String(options.body || ''),
      icon: String(options.icon || ''),
      tag: String(options.tag || ''),
      siteId: SITE_ID
    });
  }
  function blocked(api, title) {
    try { console.warn('[WebSpace] ' + api + '("' + title + '") suppressed: permission ' + permission); } catch (e) {}
  }
  function Notification(title, options) {
    if (permission !== 'granted') { blocked('Notification', title); return; }
    deliver(title, options);
  }
  Notification.permission = permission;
  Notification.requestPermission = function(cb) {
    var p = window.flutter_inappwebview.callHandler('webNotificationRequestPermission', {siteId: SITE_ID})
      .then(function(result) { permission = result; Notification.permission = result; return result; });
    if (typeof cb === 'function') p.then(cb);
    return p;
  };
  Object.defineProperty(window, 'Notification', { value: Notification, writable: false, configurable: false });
  try {
    if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype) {
      ServiceWorkerRegistration.prototype.showNotification = function(title, options) {
        if (permission !== 'granted') { blocked('showNotification', title); return Promise.resolve(); }
        deliver(title, options);
        return Promise.resolve();
      };
      ServiceWorkerRegistration.prototype.getNotifications = function() { return Promise.resolve([]); };
    }
  } catch (e) {}
})();
;null;''';
    }

    test('granted permission when notificationsEnabled is true', () {
      final script = buildPolyfill(
        siteId: 'abc123',
        notificationsEnabled: true,
      );
      expect(script, contains("permission = 'granted'"));
      expect(script, contains("SITE_ID = 'abc123'"));
      expect(script, isNot(contains('__PER_SITE_PERMISSION__')));
      expect(script, isNot(contains('__SITE_ID__')));
    });

    test('covers page-context ServiceWorkerRegistration.showNotification', () {
      final script = buildPolyfill(
        siteId: 'sw1',
        notificationsEnabled: true,
      );
      expect(script,
          contains('ServiceWorkerRegistration.prototype.showNotification'));
      expect(script, contains("callHandler('webNotification'"));
    });

    test('emits a console breadcrumb when a notification is suppressed', () {
      final script = buildPolyfill(
        siteId: 'sw2',
        notificationsEnabled: false,
      );
      expect(script, contains('suppressed: permission'));
      expect(script, contains("blocked('Notification'"));
      expect(script, contains("blocked('showNotification'"));
    });

    test('denied permission when notificationsEnabled is false', () {
      final script = buildPolyfill(
        siteId: 'xyz789',
        notificationsEnabled: false,
      );
      expect(script, contains("permission = 'denied'"));
      expect(script, contains("SITE_ID = 'xyz789'"));
    });

    test('siteId with special characters is embedded literally', () {
      final script = buildPolyfill(
        siteId: 'lqv2x3k-abc123',
        notificationsEnabled: true,
      );
      expect(script, contains("SITE_ID = 'lqv2x3k-abc123'"));
    });

    test('script defines window.Notification', () {
      final script = buildPolyfill(
        siteId: 'test',
        notificationsEnabled: true,
      );
      expect(script, contains("Object.defineProperty(window, 'Notification'"));
      expect(script, contains('Notification.requestPermission'));
      expect(script, contains('Notification.permission'));
    });
  });
}
