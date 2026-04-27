import 'dart:io';
import 'package:flutter/services.dart';

enum CurrentLocationStatus {
  ok,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
  timeout,
  unsupported,
  error,
}

class CurrentLocationFix {
  final double latitude;
  final double longitude;
  final double accuracy;

  const CurrentLocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });
}

class CurrentLocationResult {
  final CurrentLocationStatus status;
  final CurrentLocationFix? fix;
  final String? message;

  const CurrentLocationResult._(this.status, this.fix, this.message);

  factory CurrentLocationResult.ok(CurrentLocationFix fix) =>
      CurrentLocationResult._(CurrentLocationStatus.ok, fix, null);

  factory CurrentLocationResult.failure(
          CurrentLocationStatus status, String? message) =>
      CurrentLocationResult._(status, null, message);
}

/// Thin wrapper around the platform method channel that returns a single GPS
/// fix from the device's native location service. Uses Android's
/// `LocationManager` (no Google Play Services) and iOS's `CLLocationManager`.
/// Permission prompts are issued by the native side on demand.
class CurrentLocationService {
  static const _channel =
      MethodChannel('org.codeberg.theoden8.webspace/location');

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  static Future<CurrentLocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isSupported) {
      return CurrentLocationResult.failure(
        CurrentLocationStatus.unsupported,
        'Current location is not available on this platform.',
      );
    }
    try {
      final raw = await _channel.invokeMethod<dynamic>('getCurrentLocation', {
        'timeoutMs': timeout.inMilliseconds,
      });
      if (raw is! Map) {
        return CurrentLocationResult.failure(
          CurrentLocationStatus.error,
          'Unexpected response from platform.',
        );
      }
      final status = (raw['status'] as String?) ?? 'error';
      switch (status) {
        case 'ok':
          final lat = (raw['latitude'] as num?)?.toDouble();
          final lng = (raw['longitude'] as num?)?.toDouble();
          final acc = (raw['accuracy'] as num?)?.toDouble() ?? 0;
          if (lat == null || lng == null) {
            return CurrentLocationResult.failure(
              CurrentLocationStatus.error,
              'Missing coordinates in platform response.',
            );
          }
          return CurrentLocationResult.ok(
            CurrentLocationFix(latitude: lat, longitude: lng, accuracy: acc),
          );
        case 'permission_denied':
          return CurrentLocationResult.failure(
              CurrentLocationStatus.permissionDenied,
              raw['message'] as String?);
        case 'permission_denied_forever':
          return CurrentLocationResult.failure(
              CurrentLocationStatus.permissionDeniedForever,
              raw['message'] as String?);
        case 'service_disabled':
          return CurrentLocationResult.failure(
              CurrentLocationStatus.serviceDisabled,
              raw['message'] as String?);
        case 'timeout':
          return CurrentLocationResult.failure(
              CurrentLocationStatus.timeout, raw['message'] as String?);
        default:
          return CurrentLocationResult.failure(
              CurrentLocationStatus.error, raw['message'] as String?);
      }
    } on PlatformException catch (e) {
      return CurrentLocationResult.failure(
          CurrentLocationStatus.error, e.message);
    } catch (e) {
      return CurrentLocationResult.failure(
          CurrentLocationStatus.error, e.toString());
    }
  }
}
