import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/site_ids.dart';

/// The notification polyfill for the site [siteId], under its own permission.
String buildNotificationPolyfillShim({
  required SiteId siteId,
  required bool notificationsEnabled,
}) =>
    PageJs.notificationPolyfill.withConfig({
      'siteId': siteId,
      'notificationsEnabled': notificationsEnabled,
    });
