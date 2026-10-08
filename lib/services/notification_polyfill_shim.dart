import 'package:webspace/services/page_js.dart';

/// The notification polyfill for the site [siteId], under its own permission.
String buildNotificationPolyfillShim({
  required String siteId,
  required bool notificationsEnabled,
}) =>
    PageJs.notificationPolyfill.withConfig({
      'siteId': siteId,
      'notificationsEnabled': notificationsEnabled,
    });
