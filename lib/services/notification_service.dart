import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:webspace/services/log_service.dart';

class NotificationService {
  static final instance = NotificationService._();
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  void Function(String siteId)? onNotificationTapped;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    final settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onTap,
    );

    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          'webspace_web_notifications',
          'Web Notifications',
          description: 'Notifications from websites loaded in WebSpace',
          importance: Importance.high,
        ),
      );
    }

    LogService.instance.log('Notification', 'NotificationService initialized');
  }

  void _onTap(NotificationResponse response) {
    if (response.payload == null) return;
    try {
      final data = jsonDecode(response.payload!);
      final siteId = data['siteId'] as String?;
      if (siteId != null) {
        LogService.instance.log('Notification', 'Tapped notification for siteId: $siteId');
        onNotificationTapped?.call(siteId);
      }
    } catch (e) {
      LogService.instance.log('Notification', 'Failed to parse tap payload: $e', level: LogLevel.error);
    }
  }

  Future<void> show({
    required String siteId,
    required String title,
    String body = '',
    String? tag,
    String? siteUrl,
  }) async {
    if (!_initialized) await init();

    final androidDetails = AndroidNotificationDetails(
      'webspace_web_notifications',
      'Web Notifications',
      channelDescription: 'Notifications from websites loaded in WebSpace',
      importance: Importance.high,
      priority: Priority.high,
      tag: tag ?? siteId,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      macOS: iosDetails,
    );

    final payload = jsonEncode({'siteId': siteId});
    final id = siteId.hashCode ^ title.hashCode;

    await _plugin.show(id: id, title: title, body: body.isNotEmpty ? body : null, notificationDetails: details, payload: payload);
    LogService.instance.log('Notification', 'Showed notification: "$title" for siteId: $siteId');
  }

  Future<bool> requestPermission() async {
    if (!_initialized) await init();

    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await androidPlugin?.requestNotificationsPermission() ?? false;
    }

    if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }

    if (Platform.isMacOS) {
      final macPlugin = _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      return await macPlugin?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }

    return false;
  }
}
