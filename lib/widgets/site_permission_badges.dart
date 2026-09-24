import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/web_view_model.dart';

/// A permission or background capability a site currently holds, surfaced as
/// a badge on the drawer tile so the grant is visible without opening
/// per-site settings. Covers every grant the site's Permissions row counts as
/// held, plus background audio.
///
/// Only settled grants appear: `ask` (undecided), `block` and
/// [LocationMode.off] produce no badge. [SitePermissionBadge.spoofLocation]
/// and [SitePermissionBadge.virtualCamera] /
/// [SitePermissionBadge.virtualMicrophone] mark grants the app satisfies
/// synthetically — the site is fed data but no device is opened — and render
/// muted, so a glance separates "this site can see/hear the room" from "this
/// site is being played a file".
enum SitePermissionBadge {
  /// [LocationMode.live]: the real device fix reaches the page (at the
  /// site's [LocationGranularity]).
  realLocation,

  /// [LocationMode.spoof]: pages get user-picked coordinates.
  spoofLocation,

  /// [CameraAccessMode.real]: the device camera is handed to the page.
  realCamera,

  /// [CameraAccessMode.virtual]: a picked image/video is served instead.
  virtualCamera,

  /// [MicrophoneAccessMode.real]: the device microphone is handed to the
  /// page, while the site is the one on screen (MIC-014).
  realMicrophone,

  /// [MicrophoneAccessMode.virtual]: a picked audio clip is looped to the
  /// page.
  virtualMicrophone,

  /// [ScreenShareMode.virtual]: a picked image/video is served as the shared
  /// surface. There is no real-screen mode in the app, so this is the only
  /// screen-sharing grant that exists.
  virtualScreenShare,

  /// `notificationsEnabled`: the page's `Notification.permission` reads
  /// `granted` and its notifications reach the OS.
  notifications,

  /// `protectedContentAllowed == true`: the platform DRM module, and the
  /// device identifier it carries, is handed to the page. Android only; no
  /// other host consults the setting.
  protectedContent,

  /// `backgroundAudioEnabled`: the site keeps playing while another site is
  /// visible or the app is backgrounded.
  backgroundAudio,
}

/// Badges held by [model], in a stable display order (the Permissions row's
/// order, then background playback). Reads the `effective*` getters, so an
/// archive-tier site shows no badge even when the stored mode says otherwise
/// (ARCH-006). [protectedContentApplies] defaults to the host check the
/// Permissions row uses.
List<SitePermissionBadge> sitePermissionBadges(
  WebViewModel model, {
  bool? protectedContentApplies,
}) {
  return [
    switch (model.locationMode) {
      LocationMode.live => SitePermissionBadge.realLocation,
      LocationMode.spoof => SitePermissionBadge.spoofLocation,
      LocationMode.off => null,
    },
    switch (model.effectiveCameraMode) {
      CameraAccessMode.real => SitePermissionBadge.realCamera,
      CameraAccessMode.virtual => SitePermissionBadge.virtualCamera,
      CameraAccessMode.ask || CameraAccessMode.block => null,
    },
    switch (model.effectiveMicrophoneMode) {
      MicrophoneAccessMode.real => SitePermissionBadge.realMicrophone,
      MicrophoneAccessMode.virtual => SitePermissionBadge.virtualMicrophone,
      MicrophoneAccessMode.ask || MicrophoneAccessMode.block => null,
    },
    if (model.effectiveScreenShareMode == ScreenShareMode.virtual)
      SitePermissionBadge.virtualScreenShare,
    if (model.effectiveNotificationsEnabled) SitePermissionBadge.notifications,
    if ((protectedContentApplies ?? hostIsAndroid) &&
        model.effectiveProtectedContentAllowed == true)
      SitePermissionBadge.protectedContent,
    if (model.effectiveBackgroundAudioEnabled)
      SitePermissionBadge.backgroundAudio,
  ].nonNulls.toList();
}

/// True when the badge means a real device or capability is handed to the
/// site, as opposed to a synthetic stream or a background-playback exemption.
/// Matches the Permissions row, which draws the same grants in the error
/// colour.
bool _isRealDeviceAccess(SitePermissionBadge badge) => switch (badge) {
      SitePermissionBadge.realLocation ||
      SitePermissionBadge.realCamera ||
      SitePermissionBadge.realMicrophone ||
      SitePermissionBadge.notifications ||
      SitePermissionBadge.protectedContent =>
        true,
      SitePermissionBadge.spoofLocation ||
      SitePermissionBadge.virtualCamera ||
      SitePermissionBadge.virtualMicrophone ||
      SitePermissionBadge.virtualScreenShare ||
      SitePermissionBadge.backgroundAudio =>
        false,
    };

/// Filled glyph for a real device, outlined for a synthetic stream.
IconData sitePermissionBadgeIcon(SitePermissionBadge badge) => switch (badge) {
      SitePermissionBadge.realLocation => Icons.location_on,
      SitePermissionBadge.spoofLocation => Icons.location_on_outlined,
      SitePermissionBadge.realCamera => Icons.videocam,
      SitePermissionBadge.virtualCamera => Icons.videocam_outlined,
      SitePermissionBadge.realMicrophone => Icons.mic,
      SitePermissionBadge.virtualMicrophone => Icons.mic_none,
      SitePermissionBadge.virtualScreenShare => Icons.screen_share_outlined,
      SitePermissionBadge.notifications => Icons.notifications,
      SitePermissionBadge.protectedContent => Icons.shield,
      SitePermissionBadge.backgroundAudio => Icons.music_note,
    };

/// Localized "<setting>: <value>" label, e.g. "Camera access: Always allow".
/// Composed from the per-site settings strings the badge mirrors rather than
/// new copy, so the badge and the settings screen can never drift apart.
String sitePermissionBadgeLabel(AppLocalizations loc, SitePermissionBadge badge) {
  const separator = ': ';
  return switch (badge) {
    SitePermissionBadge.realLocation =>
      '${loc.siteSettingsGeolocation}$separator${loc.siteSettingsLocationLive}',
    SitePermissionBadge.spoofLocation =>
      '${loc.siteSettingsGeolocation}$separator${loc.siteSettingsLocationStatic}',
    SitePermissionBadge.realCamera =>
      '${loc.siteSettingsCameraAccess}$separator${loc.siteSettingsCameraAccessAllow}',
    SitePermissionBadge.virtualCamera =>
      '${loc.siteSettingsCameraAccess}$separator${loc.siteSettingsCameraAccessVirtual}',
    SitePermissionBadge.realMicrophone =>
      '${loc.siteSettingsMicrophoneAccess}$separator${loc.siteSettingsMicrophoneAccessAllow}',
    SitePermissionBadge.virtualMicrophone =>
      '${loc.siteSettingsMicrophoneAccess}$separator${loc.siteSettingsMicrophoneAccessVirtual}',
    SitePermissionBadge.virtualScreenShare =>
      '${loc.siteSettingsScreenShare}$separator${loc.siteSettingsScreenShareVirtual}',
    SitePermissionBadge.notifications =>
      '${loc.siteSettingsNotifications}$separator${loc.siteSettingsProtectedContentAllow}',
    SitePermissionBadge.protectedContent =>
      '${loc.siteSettingsProtectedContent}$separator${loc.siteSettingsProtectedContentAllow}',
    SitePermissionBadge.backgroundAudio => loc.siteSettingsBackgroundAudio,
  };
}

/// Permission badges for [model], or an empty box when the site holds none.
/// Sized for the drawer's site tiles: [iconSize] defaults to the smallest
/// legible glyph, and [overlay] paints a scrim so the strip stays readable on
/// top of a favicon. Badges wrap onto another row rather than grow past the
/// width the parent allows, so every grant stays visible.
class SitePermissionBadges extends StatelessWidget {
  const SitePermissionBadges({
    super.key,
    required this.model,
    this.iconSize = 10,
    this.overlay = false,
    this.protectedContentApplies,
  });

  final WebViewModel model;
  final double iconSize;
  final bool overlay;

  /// See [sitePermissionBadges]; null uses the host check.
  final bool? protectedContentApplies;

  @override
  Widget build(BuildContext context) {
    final badges = sitePermissionBadges(model,
        protectedContentApplies: protectedContentApplies);
    if (badges.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final strip = Wrap(
      alignment: WrapAlignment.center,
      spacing: iconSize * 0.1,
      runSpacing: iconSize * 0.1,
      children: [
        // No Tooltip: the strip sits inside the drawer tile's long-press
        // gestures (context menu, drag-to-reorder) and must not compete for
        // them. The label rides `semanticLabel` instead.
        for (final badge in badges)
          Icon(
            sitePermissionBadgeIcon(badge),
            size: iconSize,
            semanticLabel: sitePermissionBadgeLabel(loc, badge),
            color: _isRealDeviceAccess(badge)
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
      ],
    );

    if (!overlay) return strip;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: iconSize * 0.2, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(iconSize * 0.6),
      ),
      child: strip,
    );
  }
}
