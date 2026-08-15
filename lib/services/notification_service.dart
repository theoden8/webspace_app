import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:webspace/services/log_service.dart';

/// The OS-side identity of one posted notification. Android collapses on the
/// `(tag, id)` pair and iOS/macOS on the identifier, so this pair decides
/// whether a post replaces an earlier one or lands beside it.
@immutable
class NotificationTarget {
  final String tag;
  final int id;

  const NotificationTarget({required this.tag, required this.id});

  /// Web Notifications semantics: a post carrying a `tag` replaces the site's
  /// earlier post with that tag; a post without one is always a new
  /// notification. The tag stays namespaced to the site so two sites can use
  /// the same page-level tag without clobbering each other.
  ///
  /// [sequence] is only read for untagged posts and must differ per post.
  static NotificationTarget resolve({
    required String siteId,
    required String? tag,
    required int sequence,
  }) {
    final pageTag = (tag == null || tag.isEmpty) ? null : tag;
    return NotificationTarget(
      tag: siteId,
      id: pageTag == null
          ? sequence & 0x7fffffff
          : Object.hash(siteId, pageTag) & 0x7fffffff,
    );
  }
}

class NotificationService {
  static final instance = NotificationService._();
  NotificationService._();

  /// Seeded from the clock so ids stay distinct across process restarts —
  /// a fresh process must not reuse an id still held by a notification the
  /// previous process posted.
  int _sequence = DateTime.now().microsecondsSinceEpoch;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  Future<void>? _initInFlight;
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

  Future<void> init() {
    if (_initialized) return Future.value();
    // Memoize the in-flight future so a concurrent caller (e.g. a page's
    // webNotification handler racing startup) awaits real completion instead
    // of seeing _initialized flip early and calling _plugin.show() before
    // _plugin.initialize() has run.
    return _initInFlight ??= _doInit();
  }

  Future<void> _doInit() async {
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

    _initialized = true;
    _initInFlight = null;
    LogService.instance.log('Notification', 'NotificationService initialized');
  }

  void _onTap(NotificationResponse response) {
    if (response.payload == null) return;
    try {
      final data = jsonDecode(response.payload!);
      final siteId = data['siteId'] as String?;
      if (siteId != null) {
        LogService.instance.log(
          'Notification',
          'Tapped notification for siteId: $siteId',
          sensitivity: LogSensitivity.sensitive,
        );
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
      LogService.instance.log(
        'Notification',
        'Skipped "$title" — OS notification permission denied',
        level: LogLevel.warning,
        sensitivity: LogSensitivity.sensitive,
      );
      return;
    }

    final target = NotificationTarget.resolve(
      siteId: siteId,
      tag: tag,
      sequence: _sequence++,
    );

    final androidDetails = AndroidNotificationDetails(
      'webspace_web_notifications',
      'Web Notifications',
      channelDescription: 'Notifications from websites loaded in WebSpace',
      importance: Importance.high,
      priority: Priority.high,
      tag: target.tag,
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

    await _plugin.show(id: target.id, title: title, body: body.isNotEmpty ? body : null, notificationDetails: details, payload: payload);
    LogService.instance.log(
      'Notification',
      'Showed notification: "$title" for siteId: $siteId',
      sensitivity: LogSensitivity.sensitive,
    );
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
