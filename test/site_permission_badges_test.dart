import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_permission_badges.dart';

WebViewModel site({
  LocationMode locationMode = LocationMode.off,
  CameraAccessMode cameraMode = CameraAccessMode.ask,
  MicrophoneAccessMode microphoneMode = MicrophoneAccessMode.ask,
  bool backgroundAudioEnabled = false,
  bool isArchiveTier = false,
}) =>
    WebViewModel(
      initUrl: 'https://example.com',
      locationMode: locationMode,
      cameraMode: cameraMode,
      microphoneMode: microphoneMode,
      backgroundAudioEnabled: backgroundAudioEnabled,
      isArchiveTier: isArchiveTier,
    );

void main() {
  group('sitePermissionBadges (PERMBADGE-001)', () {
    test('a site with nothing granted has no badges', () {
      expect(sitePermissionBadges(site()), isEmpty);
    });

    test('undecided and blocked grants stay invisible', () {
      final model = site(
        cameraMode: CameraAccessMode.block,
        microphoneMode: MicrophoneAccessMode.block,
      );
      expect(sitePermissionBadges(model), isEmpty);
      expect(
        sitePermissionBadges(site(
          cameraMode: CameraAccessMode.ask,
          microphoneMode: MicrophoneAccessMode.ask,
        )),
        isEmpty,
      );
    });

    test('each grant maps to its badge', () {
      expect(sitePermissionBadges(site(locationMode: LocationMode.live)),
          [SitePermissionBadge.realLocation]);
      expect(sitePermissionBadges(site(locationMode: LocationMode.spoof)),
          [SitePermissionBadge.spoofLocation]);
      expect(sitePermissionBadges(site(cameraMode: CameraAccessMode.real)),
          [SitePermissionBadge.realCamera]);
      expect(sitePermissionBadges(site(cameraMode: CameraAccessMode.virtual)),
          [SitePermissionBadge.virtualCamera]);
      expect(
          sitePermissionBadges(
              site(microphoneMode: MicrophoneAccessMode.virtual)),
          [SitePermissionBadge.virtualMicrophone]);
      expect(sitePermissionBadges(site(backgroundAudioEnabled: true)),
          [SitePermissionBadge.backgroundAudio]);
    });

    test('badges keep a stable order: capture first, playback last', () {
      final model = site(
        locationMode: LocationMode.live,
        cameraMode: CameraAccessMode.real,
        microphoneMode: MicrophoneAccessMode.virtual,
        backgroundAudioEnabled: true,
      );
      expect(sitePermissionBadges(model), [
        SitePermissionBadge.realLocation,
        SitePermissionBadge.realCamera,
        SitePermissionBadge.virtualMicrophone,
        SitePermissionBadge.backgroundAudio,
      ]);
    });

    test('archive-tier sites show no capture or playback badge (ARCH-006)', () {
      final model = site(
        cameraMode: CameraAccessMode.real,
        microphoneMode: MicrophoneAccessMode.virtual,
        backgroundAudioEnabled: true,
        isArchiveTier: true,
      );
      expect(sitePermissionBadges(model), isEmpty);
      // Stored intent survives for when the site leaves the archive.
      expect(model.cameraMode, CameraAccessMode.real);
      expect(model.microphoneMode, MicrophoneAccessMode.virtual);
    });

    test('no two badges share a glyph', () {
      final icons =
          SitePermissionBadge.values.map(sitePermissionBadgeIcon).toSet();
      expect(icons, hasLength(SitePermissionBadge.values.length));
    });
  });

  group('SitePermissionBadges widget (PERMBADGE-002)', () {
    Widget harness(WebViewModel model) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SitePermissionBadges(model: model)),
        );

    testWidgets('renders nothing for a site without grants', (tester) async {
      await tester.pumpWidget(harness(site()));
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders one icon per grant', (tester) async {
      await tester.pumpWidget(harness(site(
        locationMode: LocationMode.live,
        cameraMode: CameraAccessMode.real,
        microphoneMode: MicrophoneAccessMode.virtual,
        backgroundAudioEnabled: true,
      )));
      expect(find.byType(Icon), findsNWidgets(4));
      expect(
          find.byIcon(sitePermissionBadgeIcon(SitePermissionBadge.realCamera)),
          findsOneWidget);
    });

    testWidgets('real device access is tinted apart from simulated grants',
        (tester) async {
      await tester.pumpWidget(harness(site(
        cameraMode: CameraAccessMode.real,
        microphoneMode: MicrophoneAccessMode.virtual,
      )));
      final context = tester.element(find.byType(SitePermissionBadges));
      final scheme = Theme.of(context).colorScheme;
      final real = tester.widget<Icon>(find
          .byIcon(sitePermissionBadgeIcon(SitePermissionBadge.realCamera)));
      final simulated = tester.widget<Icon>(find.byIcon(
          sitePermissionBadgeIcon(SitePermissionBadge.virtualMicrophone)));
      expect(real.color, scheme.error);
      expect(simulated.color, scheme.onSurfaceVariant);
    });

    testWidgets('each badge carries a localized label for screen readers',
        (tester) async {
      await tester.pumpWidget(harness(site(cameraMode: CameraAccessMode.real)));
      final context = tester.element(find.byType(SitePermissionBadges));
      final loc = AppLocalizations.of(context);
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.semanticLabel,
          '${loc.siteSettingsCameraAccess}: ${loc.siteSettingsCameraAccessAllow}');
      expect(icon.semanticLabel,
          sitePermissionBadgeLabel(loc, SitePermissionBadge.realCamera));
    });
  });
}
