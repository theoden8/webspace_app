import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:webspace/services/log_service.dart';

class NotificationService {
  static final instance = NotificationService._();
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  void Function(String siteId)? onNotificationTapped;

  /// Listeners are invoked whenever [permissionGranted] changes (e.g.
  /// after a `requestPermission()` call). Used by the per-site settings
  /// UI to refresh the "denied" subtitle reactively.
  final List<VoidCallback> _permissionListeners = [];
  bool? _permissionGranted;

  /// Last known OS-level notification permission result. `null` means we
  /// haven't asked yet (cold state). `true` is granted; `false` is denied.
  /// On iOS / macOS / Android the value is observed via the platform-
  /// specific request API. Other platforms return `null`.
  bool? get permissionGranted => _permissionGranted;

  void addPermissionListener(VoidCallback cb) {
    _permissionListeners.add(cb);
  }

  void removePermissionListener(VoidCallback cb) {
    _permissionListeners.remove(cb);
  }

  void _notifyPermissionListeners() {
    for (final cb in List<VoidCallback>.from(_permissionListeners)) {
      try {
        cb();
      } catch (_) {
        // Listeners are UI refreshers; never let one throw take down others.
      }
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    // Linux requires its own InitializationSettings or
    // FlutterLocalNotificationsPlugin.initialize throws
    // ArgumentError("Linux settings must be set when targeting Linux
    // platform"). defaultActionName is the label shown on the click
    // action of a notification — "Open" matches what most freedesktop
    // notification daemons display.
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );
    final settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      macOS: iosSettings,
      linux: linuxSettings,
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

  Future<void> _ensurePermission() async {
    if (_permissionGranted == true) return;
    await requestPermission();
  }

  Future<void> show({
    required String siteId,
    required String title,
    String body = '',
    String? tag,
    String? siteUrl,
  }) async {
    if (!_initialized) await init();
    await _ensurePermission();
    if (_permissionGranted != true) {
      LogService.instance.log('Notification', 'Skipped "$title" — OS notification permission denied', level: LogLevel.warning);
      return;
    }

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

    bool granted = false;
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      granted = await androidPlugin?.requestNotificationsPermission() ?? false;
    } else if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      granted = await iosPlugin?.requestPermissions(
              alert: true, badge: true, sound: true) ??
          false;
    } else if (Platform.isMacOS) {
      final macPlugin = _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      granted = await macPlugin?.requestPermissions(
              alert: true, badge: true, sound: true) ??
          false;
    }
    final changed = _permissionGranted != granted;
    _permissionGranted = granted;
    LogService.instance.log(
        'Notification', 'OS permission: ${granted ? "granted" : "denied"}');
    if (changed) _notifyPermissionListeners();
    return granted;
  }
}
