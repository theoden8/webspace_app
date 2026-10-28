import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/screens/site_permissions.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/widgets/site_permission_chip.dart';

SitePermissionValues _values({
  bool archived = false,
  CameraAccessMode camera = CameraAccessMode.ask,
  MicrophoneAccessMode microphone = MicrophoneAccessMode.ask,
  ScreenShareMode screenShare = ScreenShareMode.ask,
  LocationMode location = LocationMode.off,
  bool notifications = false,
  bool? protectedContent,
}) =>
    SitePermissionValues(
      archived: archived,
      captures: CaptureGrants(
        camera: (mode: camera, source: null),
        microphone: (mode: microphone, source: null),
        screenShare: (mode: screenShare, source: null),
      ),
      notificationsEnabled: notifications,
      backgroundAudioEnabled: false,
      protectedContentAllowed: protectedContent,
      locationMode: location,
      liveLocationGranularity: LocationGranularity.gps,
      hasStaticCoordinates: false,
      spoofTimezone: null,
      spoofTimezoneFromLocation: false,
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
      timezonePreview: () => 'Europe/Paris',
      coordinatesPreview: () => '48.8566, 2.3522',
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

  group('the screen sharing sheet (SHARE-002)', () {
    tearDown(() => debugHostSharesScreen = null);

    Future<void> openSheet(WidgetTester tester,
        {ValueChanged<SitePermissionValues>? onChanged}) async {
      await _pump(tester, values: _values(), onChanged: onChanged);
      await tester.tap(find.text('Screen sharing'));
      await tester.pumpAndSettle();
    }

    RadioListTile<SitePermissionState> tileOf(WidgetTester tester,
            {required String label}) =>
        tester.widget<RadioListTile<SitePermissionState>>(find.ancestor(
          of: find.text(label).last,
          matching: find.byType(RadioListTile<SitePermissionState>),
        ));

    testWidgets('where the real screen is not offered, Allowed is greyed and '
        'says why', (tester) async {
      debugHostSharesScreen = false;
      await openSheet(tester);
      expect(tileOf(tester, label: 'Allowed').onChanged, isNull);
      expect(find.textContaining('on Android, on Linux and on macOS 14'),
          findsOneWidget);
      expect(find.text('Always allow'), findsNothing);
    });

    testWidgets('on Android, Always allow warns what a share shows, and '
        'Cancel keeps Ask (SHARE-019)',
        (tester) async {
      debugHostSharesScreen = true;
      final changes = <SitePermissionValues>[];
      await openSheet(tester, onChanged: changes.add);
      expect(tileOf(tester, label: 'Always allow').onChanged, isNotNull);
      await tester.tap(find.text('Always allow').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('other apps and notifications'),
          findsOneWidget, reason: 'the warning names what the site will see');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });

    testWidgets('on Android, confirming the warning stores the real grant',
        (tester) async {
      debugHostSharesScreen = true;
      final changes = <SitePermissionValues>[];
      await openSheet(tester, onChanged: changes.add);
      await tester.tap(find.text('Always allow').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow').last);
      await tester.pumpAndSettle();
      expect(changes.last.captures.screenShare.mode, ScreenShareMode.real);
    });
  });

  testWidgets('location off reads as Blocked, never as a pass-through',
      (tester) async {
    await _pump(tester, values: _values(location: LocationMode.off));
    expect(find.text('Blocked'), findsWidgets);
  });

  testWidgets('the microphone sheet offers a real grant (MIC-002)',
      (tester) async {
    // Previously a greyed row explaining that no real-microphone mode
    // existed. The mode exists now, so the row has to be selectable: an inert
    // "Allowed" would tell the user the opposite of what the app does.
    await _pump(tester, values: _values());
    await tester.tap(find.text('Microphone access'));
    await tester.pumpAndSettle();

    final allowed = tester.widget<RadioListTile<SitePermissionState>>(
      find.ancestor(
        of: find.text('Always allow').last,
        matching: find.byType(RadioListTile<SitePermissionState>),
      ),
    );
    expect(allowed.onChanged, isNotNull, reason: 'Allowed must be selectable');
    expect(find.textContaining('never opens a real microphone'), findsNothing);
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
        timezonePreview: () => 'Europe/Paris',
        coordinatesPreview: () => '48.8566, 2.3522',
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

  testWidgets('choosing a state reports it to the caller (CAM-002)', (tester) async {
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
    expect(reported?.captures.camera.mode, CameraAccessMode.block);
  });

  testWidgets('timezone sits inside the location sheet, not in the list',
      (tester) async {
    // It is the same disclosure as the coordinates it can be derived from, so
    // it belongs with them. It is not a capability, though, so it gets no row
    // of its own and no state chip: it is a property of the location sheet.
    await _pump(tester, values: _values(location: LocationMode.spoof));
    expect(find.text('Timezone'), findsNothing);

    await tester.tap(find.text('Geolocation'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);

    // The "from location" entry names what the coordinates resolve to, so
    // choosing it is not a guess. Only visible once the menu is open, which is
    // the point: the preview is computed per rebuild, not snapshotted.
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    expect(find.textContaining('Europe/Paris'), findsWidgets);
  });

  testWidgets('the timezone stays visible whichever location state is chosen',
      (tester) async {
    // Rendered as a sheet footer rather than under one option: a site with
    // location blocked can still be handed a spoofed zone.
    await _pump(tester, values: _values(location: LocationMode.off));
    await tester.tap(find.text('Geolocation'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);
  });

  testWidgets('tracking protection forces the timezone to follow coordinates',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SitePermissionsScreen(
        host: 'example.com',
        values: _values(location: LocationMode.spoof)
            .copyWith(hasStaticCoordinates: true),
        trackingProtectionEnabled: true,
        onChanged: (_) {},
        onOpenLocationPicker: () async => true,
        onEnableNotifications: () async {},
        timezonePreview: () => 'Europe/Paris',
        coordinatesPreview: () => '48.8566, 2.3522',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Geolocation'));
    await tester.pumpAndSettle();
    final field = tester.widget<DropdownButtonFormField<String?>>(
      find.byType(DropdownButtonFormField<String?>),
    );
    expect(field.onChanged, isNull,
        reason: 'forced to follow the spoofed geo, so it must be inert');
  });

  testWidgets('an archived site shows its grants held off and locked',
      (tester) async {
    await _pump(
      tester,
      values: _values(
        archived: true,
        camera: CameraAccessMode.real,
        microphone: MicrophoneAccessMode.real,
        screenShare: ScreenShareMode.virtual,
        notifications: true,
      ),
    );
    final chips = tester
        .widgetList<SitePermissionChip>(find.byType(SitePermissionChip))
        .toList();
    for (final title in const [
      'Camera access',
      'Microphone access',
      'Screen sharing',
    ]) {
      final row = find.ancestor(
          of: find.text(title), matching: find.byType(ListTile));
      final chip = tester.widget<SitePermissionChip>(find.descendant(
          of: row, matching: find.byType(SitePermissionChip)));
      expect(chip.state, SitePermissionState.blocked, reason: title);
      expect(chip.dimmed, isTrue, reason: title);
      expect(tester.widget<ListTile>(row).onTap, isNull, reason: title);
    }
    expect(chips, isNotEmpty);
    expect(find.text('Fixed for sites in an archive'), findsWidgets);
  });
}
