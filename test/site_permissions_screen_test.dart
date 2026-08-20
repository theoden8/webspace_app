import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/site_permissions.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/site_permission_state.dart';

SitePermissionValues _values({
  CameraAccessMode camera = CameraAccessMode.ask,
  MicrophoneAccessMode microphone = MicrophoneAccessMode.ask,
  LocationMode location = LocationMode.off,
  bool notifications = false,
  bool? protectedContent,
}) =>
    SitePermissionValues(
      cameraMode: camera,
      virtualCameraSource: null,
      microphoneMode: microphone,
      virtualMicrophoneSource: null,
      notificationsEnabled: notifications,
      backgroundAudioEnabled: false,
      protectedContentAllowed: protectedContent,
      locationMode: location,
      liveLocationGranularity: LocationGranularity.gps,
      hasStaticCoordinates: false,
    );

Future<void> _pump(
  WidgetTester tester, {
  required SitePermissionValues values,
  ValueChanged<SitePermissionValues>? onChanged,
  bool trackingProtection = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SitePermissionsScreen(
      host: 'example.com',
      values: values,
      trackingProtectionEnabled: trackingProtection,
      onChanged: onChanged ?? (_) {},
      onOpenLocationPicker: () async => false,
      onEnableNotifications: () async {},
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every capability reports a state chip', (tester) async {
    await _pump(
      tester,
      values: _values(
        camera: CameraAccessMode.virtual,
        location: LocationMode.live,
      ),
    );
    // Camera simulated, location allowed, microphone ask, protected content
    // ask. The point of the screen is that these are comparable at a glance,
    // so all four words must be on it at once.
    expect(find.text('Simulated'), findsOneWidget);
    expect(find.text('Allowed'), findsWidgets);
    expect(find.text('Ask'), findsWidgets);
  });

  testWidgets('location off reads as Blocked, never as a pass-through',
      (tester) async {
    await _pump(tester, values: _values(location: LocationMode.off));
    expect(find.text('Blocked'), findsWidgets);
  });

  testWidgets('the microphone sheet shows Allowed as unavailable',
      (tester) async {
    // The greyed row is the guarantee made visible: WebSpace has no
    // real-microphone mode at all. Omitting it would hide the reassurance,
    // which is what the old hint-popup did.
    await _pump(tester, values: _values());
    await tester.tap(find.text('Microphone access'));
    await tester.pumpAndSettle();

    final allowed = tester.widget<RadioListTile<SitePermissionState>>(
      find.ancestor(
        of: find.text('Allowed').last,
        matching: find.byType(RadioListTile<SitePermissionState>),
      ),
    );
    expect(allowed.onChanged, isNull, reason: 'Allowed must be inert');
    expect(find.textContaining('never opens a real microphone'), findsOneWidget);
  });

  testWidgets('a capability another setting owns is inert and says why',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SitePermissionsScreen(
        host: 'example.com',
        values: _values(),
        notificationsBlockedBySite: 'bank.example',
        onChanged: (_) {},
        onOpenLocationPicker: () async => false,
        onEnableNotifications: () async {},
      ),
    ));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Notifications'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.onTap, isNull, reason: 'a locked row must not open its sheet');
    // The reason names the conflicting site rather than failing silently.
    expect(find.textContaining('bank.example'), findsOneWidget);
  });

  testWidgets('choosing a state reports it to the caller', (tester) async {
    SitePermissionValues? reported;
    await _pump(
      tester,
      values: _values(),
      onChanged: (v) => reported = v,
    );
    await tester.tap(find.text('Camera access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always block'));
    await tester.pumpAndSettle();
    expect(reported?.cameraMode, CameraAccessMode.block);
  });
}
