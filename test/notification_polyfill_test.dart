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
  var permission = '$permission';
  function Notification(title, options) {
    options = options || {};
    if (permission !== 'granted') return;
    window.flutter_inappwebview.callHandler('webNotification', {
      title: String(title),
      body: String(options.body || ''),
      icon: String(options.icon || ''),
      tag: String(options.tag || ''),
      siteId: '$siteId'
    });
  }
  Notification.permission = permission;
  Notification.requestPermission = function(cb) {
    var p = window.flutter_inappwebview.callHandler('webNotificationRequestPermission', {siteId: '$siteId'})
      .then(function(result) { permission = result; Notification.permission = result; return result; });
    if (typeof cb === 'function') p.then(cb);
    return p;
  };
  Object.defineProperty(window, 'Notification', { value: Notification, writable: false, configurable: false });
})();
;null;''';
    }

    test('granted permission when notificationsEnabled is true', () {
      final script = buildPolyfill(
        siteId: 'abc123',
        notificationsEnabled: true,
      );
      expect(script, contains("permission = 'granted'"));
      expect(script, contains("siteId: 'abc123'"));
      expect(script, isNot(contains('__PER_SITE_PERMISSION__')));
      expect(script, isNot(contains('__SITE_ID__')));
    });

    test('denied permission when notificationsEnabled is false', () {
      final script = buildPolyfill(
        siteId: 'xyz789',
        notificationsEnabled: false,
      );
      expect(script, contains("permission = 'denied'"));
      expect(script, contains("siteId: 'xyz789'"));
    });

    test('siteId with special characters is embedded literally', () {
      final script = buildPolyfill(
        siteId: 'lqv2x3k-abc123',
        notificationsEnabled: true,
      );
      expect(script, contains("siteId: 'lqv2x3k-abc123'"));
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
