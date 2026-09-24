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

  group('fitSitePermissionBadges (PERMBADGE-005)', () {
    const all = [
      SitePermissionBadge.spoofLocation,
      SitePermissionBadge.realCamera,
      SitePermissionBadge.virtualMicrophone,
      SitePermissionBadge.notifications,
      SitePermissionBadge.backgroundAudio,
    ];

    test('everything is shown when it fits', () {
      final fit = fitSitePermissionBadges(all, all.length);
      expect(fit.shown, all);
      expect(fit.hidden, isEmpty);
    });

    test('real device grants are kept ahead of simulated ones', () {
      final fit = fitSitePermissionBadges(all, 2);
      expect(fit.shown,
          [SitePermissionBadge.realCamera, SitePermissionBadge.notifications]);
      expect(fit.hidden, [
        SitePermissionBadge.spoofLocation,
        SitePermissionBadge.virtualMicrophone,
        SitePermissionBadge.backgroundAudio,
      ]);
    });

    test('shown badges keep the display order', () {
      final fit = fitSitePermissionBadges(all, 3);
      expect(fit.shown, [
        SitePermissionBadge.spoofLocation,
        SitePermissionBadge.realCamera,
        SitePermissionBadge.notifications,
      ]);
    });

    test('no room folds everything into the counter', () {
      expect(fitSitePermissionBadges(all, 0).shown, isEmpty);
      expect(fitSitePermissionBadges(all, -1).hidden, all);
    });
  });

  group('SitePermissionBadges in a tile (PERMBADGE-005)', () {
    Widget boxed(WebViewModel model, double width, {bool overlay = false}) =>
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Center(
                  child: SitePermissionBadges(
                    model: model,
                    iconSize: overlay ? 9 : 12,
                    overlay: overlay,
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('a crowded strip folds into a counter inside its bounds',
        (tester) async {
      // The narrow drawer tile's favicon is 48 wide.
      await tester.pumpWidget(boxed(everyGrant(), 48, overlay: true));
      expect(tester.takeException(), isNull);
      final strip = tester.getRect(find.byType(SitePermissionBadges));
      expect(strip.width, lessThanOrEqualTo(48));
      for (final element in find.byType(Icon).evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        expect(rect.left, greaterThanOrEqualTo(strip.left));
        expect(rect.right, lessThanOrEqualTo(strip.right));
      }
      final shown = find.byType(Icon).evaluate().length;
      final badges = sitePermissionBadges(everyGrant());
      expect(shown, lessThan(badges.length));
      expect(find.text('+${badges.length - shown}'), findsOneWidget);
    });

    testWidgets('the counter names the folded grants for screen readers',
        (tester) async {
      await tester.pumpWidget(boxed(everyGrant(), 48, overlay: true));
      final context = tester.element(find.byType(SitePermissionBadges));
      final loc = AppLocalizations.of(context);
      final counter = tester.widget<Text>(find.textContaining('+'));
      final shownIcons = tester
          .widgetList<Icon>(find.byType(Icon))
          .map((i) => i.icon)
          .toSet();
      final folded = sitePermissionBadges(everyGrant())
          .where((b) => !shownIcons.contains(sitePermissionBadgeIcon(b)));
      expect(counter.semanticsLabel,
          folded.map((b) => sitePermissionBadgeLabel(loc, b)).join(', '));
    });

    testWidgets('a strip with room shows every badge and no counter',
        (tester) async {
      await tester.pumpWidget(boxed(everyGrant(), 400));
      expect(find.byType(Icon),
          findsNWidgets(sitePermissionBadges(everyGrant()).length));
      expect(find.textContaining('+'), findsNothing);
    });
  });
}
