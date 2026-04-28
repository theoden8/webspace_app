import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/log_service.dart';

class NotificationService {
  static final instance = NotificationService._();
  NotificationService._();

  void Function(String siteId)? onNotificationTapped;

  Future<void> init() async {
    LogService.instance.log('Notification', 'NotificationService initialized (stub — flutter_local_notifications not yet wired)');
  }

  Future<void> show({
    required String siteId,
    required String title,
    String body = '',
    String? tag,
    String? siteUrl,
  }) async {
    String? faviconUrl;
    if (siteUrl != null) {
      faviconUrl = await getFaviconUrl(siteUrl);
    }
    LogService.instance.log(
      'Notification',
      'SHOW: "$title" body="$body" siteId=$siteId tag=$tag favicon=${faviconUrl ?? 'none'}',
    );
    // TODO: wire to flutter_local_notifications when dependency is added to pubspec.yaml + lockfile
  }

  Future<bool> requestPermission() async {
    LogService.instance.log('Notification', 'requestPermission called (stub)');
    return true;
  }
}
