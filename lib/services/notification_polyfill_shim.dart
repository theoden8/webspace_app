import 'package:webspace/services/page_js.dart';

/// The notification polyfill, under the site's own permission. It carries no
/// site id: every frame runs it, and the handler names the site (NOTIF-010).
String buildNotificationPolyfillShim({required bool notificationsEnabled}) =>
    PageJs.notificationPolyfill.withConfig({
      'notificationsEnabled': notificationsEnabled,
    });
