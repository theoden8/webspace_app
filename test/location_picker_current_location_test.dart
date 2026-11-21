import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/services/current_location_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/app_prefs.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/localized.dart';

/// LOC-008: the picker's "Use current location" button, driven against the
/// native location channel as the plugins answer it. The native side (the
/// permission prompt, a single fix, LocationManager without Play Services)
/// is the platform's; this holds what the picker does with each answer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.codeberg.theoden8.webspace/location');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppLocalizations en;
  late FakeOutbound outbound;
  late List<MethodCall> calls;
  late Future<Object?> Function() answer;

  setUpAll(() async => en = await AppLocalizations.delegate.load(const Locale('en')));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
    outboundHttp = outbound =
        FakeOutbound(responder: (_) => http.Response('', 500));
    CurrentLocationService.debugIsSupportedOverride = true;
    calls = [];
    answer = () async => <String, Object?>{
          'status': 'ok', 'latitude': 35.6762, 'longitude': 139.6503, 'accuracy': 12.0,
        };
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return answer();
    });
  });

  tearDown(() {
    CurrentLocationService.debugIsSupportedOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
    resetOutboundHttp();
  });

  String field(WidgetTester tester, {required Localized label}) => tester
      .widget<TextField>(find.widgetWithText(TextField, label.toString()))
      .controller!
      .text;

  Future<void> open(WidgetTester tester) => pumpLocalized(tester,
      home: const LocationPickerScreen(
          initialLatitude: 1.5, initialLongitude: 2.5, initialAccuracy: 50));

  Future<void> useCurrent(WidgetTester tester) async {
    await tester.tap(find.text(en.locationPickerUseCurrentLocation.toString()));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('LOC-008: no button where no native location service is wired',
      (tester) async {
    CurrentLocationService.debugIsSupportedOverride = false;
    await open(tester);
    expect(find.text(en.locationPickerUseCurrentLocation.toString()), findsNothing);
    expect(find.byIcon(Icons.my_location), findsNothing);
  });

  testWidgets('LOC-008: a fix fills the three inputs and asks nothing of the network',
      (tester) async {
    await open(tester);
    await useCurrent(tester);
    expect(calls.map((c) => c.method), ['getCurrentLocation'],
        reason: 'one single-fix request per tap');
    expect(calls.single.arguments, {'timeoutMs': 30000, 'accuracy': 'fine'});
    expect(field(tester, label: en.locationPickerLatitudeLabel), '35.676200');
    expect(field(tester, label: en.locationPickerLongitudeLabel), '139.650300');
    expect(field(tester, label: en.locationPickerAccuracyLabel), '12.0');
    expect(find.byType(FlutterMap), findsNothing, reason: 'the map stays unloaded');
    expect(outbound.queries, isEmpty);
    expect(outbound.requested, isEmpty);
  });

  final failures = <String, Localized Function(AppLocalizations)>{
    'permission_denied': (l) => l.locationPickerPermissionDenied,
    'permission_denied_forever': (l) => l.locationPickerPermissionDeniedForever,
    'service_disabled': (l) => l.locationPickerServiceDisabled,
    'timeout': (l) => l.locationPickerTimeout,
  };

  test('LOC-008: each failure has a message of its own', () {
    final messages = [
      ...failures.values.map((m) => m(en).toString()),
      en.locationPickerUnsupported.toString(),
    ];
    expect(messages.toSet(), hasLength(messages.length));
  });

  for (final MapEntry(key: status, value: message) in failures.entries) {
    testWidgets('LOC-008: $status leaves the inputs and says so', (tester) async {
      answer = () async => <String, Object?>{'status': status};
      await open(tester);
      final labels = [
        en.locationPickerLatitudeLabel,
        en.locationPickerLongitudeLabel,
        en.locationPickerAccuracyLabel,
      ];
      final before = [for (final l in labels) field(tester, label: l)];
      await useCurrent(tester);
      expect(find.text(message(en).toString()), findsOneWidget);
      expect([for (final l in labels) field(tester, label: l)], before);
    });
  }

  testWidgets('LOC-008: a second tap while a fix is out asks nothing more',
      (tester) async {
    final reply = Completer<Object?>();
    answer = () => reply.future;
    await open(tester);
    await useCurrent(tester);
    expect(find.text(en.locationPickerGettingLocation.toString()), findsOneWidget);
    await tester.tap(find.text(en.locationPickerGettingLocation.toString()));
    await tester.pump();
    expect(calls, hasLength(1));
    reply.complete(<String, Object?>{'status': 'timeout'});
    await tester.pump();
    await tester.pump();
    expect(find.text(en.locationPickerUseCurrentLocation.toString()), findsOneWidget);
    expect(find.text(en.locationPickerTimeout.toString()), findsOneWidget);
  });
}
