import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_permission_badges.dart';

WebViewModel site({
  LocationMode locationMode = LocationMode.off,
  CameraAccessMode cameraMode = CameraAccessMode.ask,
  MicrophoneAccessMode microphoneMode = MicrophoneAccessMode.ask,
  ScreenShareMode screenShareMode = ScreenShareMode.ask,
  bool notificationsEnabled = false,
  bool? protectedContentAllowed,
  bool trackingProtectionEnabled = false,
  bool backgroundAudioEnabled = false,
  bool isArchiveTier = false,
}) =>
    WebViewModel(
      initUrl: 'https://example.com',
      locationMode: locationMode,
      cameraMode: cameraMode,
      microphoneMode: microphoneMode,
      screenShareMode: screenShareMode,
      notificationsEnabled: notificationsEnabled,
      protectedContentAllowed: protectedContentAllowed,
      trackingProtectionEnabled: trackingProtectionEnabled,
      backgroundAudioEnabled: backgroundAudioEnabled,
      isArchiveTier: isArchiveTier,
    );

/// Every grant a site can hold at once.
WebViewModel everyGrant({bool isArchiveTier = false}) => site(
      locationMode: LocationMode.live,
      cameraMode: CameraAccessMode.real,
      microphoneMode: MicrophoneAccessMode.real,
      screenShareMode: ScreenShareMode.virtual,
      notificationsEnabled: true,
      protectedContentAllowed: true,
      backgroundAudioEnabled: true,
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
      expect(sitePermissionBadges(site(notificationsEnabled: true)),
          [SitePermissionBadge.notifications]);
      expect(
          sitePermissionBadges(site(protectedContentAllowed: true),
              protectedContentApplies: true),
          [SitePermissionBadge.protectedContent]);
    });

    test('protected content is badged only where the host consults it', () {
      final model = site(protectedContentAllowed: true);
      expect(sitePermissionBadges(model, protectedContentApplies: false),
          isEmpty);
    });

    test('protected content follows its effective value', () {
      expect(
          sitePermissionBadges(site(protectedContentAllowed: false),
              protectedContentApplies: true),
          isEmpty);
      expect(
          sitePermissionBadges(site(), protectedContentApplies: true),
          isEmpty);
      // Tracking Protection forces DRM off whatever was stored.
      expect(
          sitePermissionBadges(
              site(
                  protectedContentAllowed: true,
                  trackingProtectionEnabled: true),
              protectedContentApplies: true),
          isEmpty);
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

    test('every grant surfaces in the Permissions row order', () {
      expect(sitePermissionBadges(everyGrant(), protectedContentApplies: true), [
        SitePermissionBadge.realLocation,
        SitePermissionBadge.realCamera,
        SitePermissionBadge.realMicrophone,
        SitePermissionBadge.virtualScreenShare,
        SitePermissionBadge.notifications,
        SitePermissionBadge.protectedContent,
        SitePermissionBadge.backgroundAudio,
      ]);
    });

    test('archive-tier sites show no capture or playback badge (ARCH-006)', () {
      final model = site(
        cameraMode: CameraAccessMode.real,
        microphoneMode: MicrophoneAccessMode.virtual,
        notificationsEnabled: true,
        protectedContentAllowed: true,
        backgroundAudioEnabled: true,
        isArchiveTier: true,
      );
      expect(sitePermissionBadges(model, protectedContentApplies: true),
          isEmpty);
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

    testWidgets('a notification grant is badged in the error colour',
        (tester) async {
      await tester.pumpWidget(harness(site(notificationsEnabled: true)));
      final context = tester.element(find.byType(SitePermissionBadges));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon,
          sitePermissionBadgeIcon(SitePermissionBadge.notifications));
      expect(icon.color, Theme.of(context).colorScheme.error);
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

  group('SitePermissionBadges in a tile (PERMBADGE-005)', () {
    Widget boxed(Widget strip) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Center(child: strip)),
        );

    int rows(WidgetTester tester) => tester
        .widgetList<Icon>(find.byType(Icon))
        .map((icon) => tester.getRect(find.byWidget(icon)).top)
        .toSet()
        .length;

    void expectInside(WidgetTester tester, Rect bounds) {
      for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
        final rect = tester.getRect(find.byWidget(icon));
        expect(bounds.contains(rect.topLeft), isTrue);
        expect(bounds.contains(rect.bottomRight - const Offset(0.01, 0.01)),
            isTrue);
      }
    }

    final allBadges =
        sitePermissionBadges(everyGrant(), protectedContentApplies: true);

    testWidgets('every grant wraps inside the favicon overlay',
        (tester) async {
      // The narrow drawer tile's favicon is 48 wide.
      await tester.pumpWidget(boxed(SizedBox(
        width: 48,
        child: Center(
          child: SitePermissionBadges(
            model: everyGrant(),
            iconSize: 9,
            overlay: true,
            protectedContentApplies: true,
          ),
        ),
      )));
      expect(tester.takeException(), isNull);
      expect(find.byType(Icon), findsNWidgets(allBadges.length));
      expect(find.byType(Text), findsNothing);
      final strip = tester.getRect(find.byType(SitePermissionBadges));
      expect(strip.width, lessThanOrEqualTo(48));
      expect(rows(tester), 2);
      expectInside(tester, strip);
    });

    testWidgets('every grant fits beside the name in the narrowest wide tile',
        (tester) async {
      // A tile is wide once it is 1.5 x 88 = 132 across. Less padding (24),
      // favicon (36) and gap (12), that leaves 60 beside the favicon, of
      // which the strip gets half, in a content height of 80.
      await tester.pumpWidget(boxed(SizedBox(
        height: 80,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 30),
            child: SitePermissionBadges(
              model: everyGrant(),
              iconSize: 12,
              protectedContentApplies: true,
            ),
          ),
        ),
      )));
      expect(tester.takeException(), isNull);
      expect(find.byType(Icon), findsNWidgets(allBadges.length));
      final strip = tester.getRect(find.byType(SitePermissionBadges));
      expect(strip.width, lessThanOrEqualTo(30));
      expect(strip.height, lessThanOrEqualTo(80));
      expectInside(tester, strip);
    });

    testWidgets('a strip with room keeps every badge on one row',
        (tester) async {
      await tester.pumpWidget(boxed(SizedBox(
        width: 400,
        child: Center(
          child: SitePermissionBadges(
            model: everyGrant(),
            iconSize: 12,
            protectedContentApplies: true,
          ),
        ),
      )));
      expect(find.byType(Icon), findsNWidgets(allBadges.length));
      expect(rows(tester), 1);
    });
  });
}
