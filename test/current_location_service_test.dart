import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/current_location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('org.codeberg.theoden8.webspace/location');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Map<String, dynamic> response;

  setUp(() {
    CurrentLocationService.debugIsSupportedOverride = true;
    calls = [];
    response = {
      'status': 'ok',
      'latitude': 35.6762,
      'longitude': 139.6503,
      'accuracy': 12.0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });
  });

  tearDown(() {
    CurrentLocationService.debugIsSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('CurrentLocationService.getCurrentLocation', () {
    test('default accuracy is fine — back-compat for existing callers', () async {
      // The location picker's "Use current location" button has always
      // called this without specifying accuracy. It must keep getting
      // the GPS-allowed path so users don't see a regression.
      await CurrentLocationService.getCurrentLocation();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map;
      expect(args['accuracy'], equals('fine'));
    });

    test('coarse accuracy is forwarded to the platform channel as the string "coarse"', () async {
      // The native plugins switch on this string to route Android to
      // NETWORK_PROVIDER-only / iOS to kCLLocationAccuracyKilometer.
      // The string contract is the API surface — assert it explicitly so
      // a typo or rename can't silently fall back to fine.
      await CurrentLocationService.getCurrentLocation(
        accuracy: LocationAccuracy.coarse,
      );
      final args = calls.single.arguments as Map;
      expect(args['accuracy'], equals('coarse'));
    });

    test('parses a successful platform response into CurrentLocationResult.ok', () async {
      final res = await CurrentLocationService.getCurrentLocation();
      expect(res.status, equals(CurrentLocationStatus.ok));
      expect(res.fix, isNotNull);
      expect(res.fix!.latitude, equals(35.6762));
      expect(res.fix!.longitude, equals(139.6503));
      expect(res.fix!.accuracy, equals(12.0));
    });

    test('coarse + permission_denied surfaces as permissionDenied (no GPS escalation)', () async {
      // Android coarse-only mode requests ACCESS_COARSE_LOCATION only; if
      // the user denies, we get permission_denied without the OS having
      // ever offered the Precise toggle. The Dart wrapper must surface
      // that path identically to the fine-mode denial.
      response = {
        'status': 'permission_denied',
        'message': 'Location permission was not granted.',
      };
      final res = await CurrentLocationService.getCurrentLocation(
        accuracy: LocationAccuracy.coarse,
      );
      expect(res.status, equals(CurrentLocationStatus.permissionDenied));
    });
  });
}
