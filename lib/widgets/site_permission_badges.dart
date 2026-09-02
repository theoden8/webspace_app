import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/screen_share.dart';
import 'package:webspace/web_view_model.dart';

/// A capture/background capability a site currently holds, surfaced as a
/// badge on the drawer tile so the grant is visible without opening
/// per-site settings.
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

  /// [MicrophoneAccessMode.virtual]: a picked audio clip is looped to the
  /// page. There is no real-microphone mode in the app, so this is the only
  /// microphone grant that exists.
  virtualMicrophone,

  /// [ScreenShareMode.virtual]: a picked image/video is served as the shared
  /// surface. There is no real-screen mode in the app, so this is the only
  /// screen-sharing grant that exists.
  virtualScreenShare,

  /// `backgroundAudioEnabled`: the site keeps playing while another site is
  /// visible or the app is backgrounded.
  backgroundAudio,
}

/// Badges held by [model], in a stable display order (capture first, then
/// background playback). Reads the `effective*` getters, so an archive-tier
/// site shows no capture badge even when the stored mode says otherwise
/// (ARCH-006).
List<SitePermissionBadge> sitePermissionBadges(WebViewModel model) {
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
    if (model.effectiveMicrophoneMode == MicrophoneAccessMode.virtual)
      SitePermissionBadge.virtualMicrophone,
    if (model.effectiveScreenShareMode == ScreenShareMode.virtual)
      SitePermissionBadge.virtualScreenShare,
    if (model.effectiveBackgroundAudioEnabled)
      SitePermissionBadge.backgroundAudio,
  ].nonNulls.toList();
}

/// True when the badge means a real device is opened for the site, as
/// opposed to a synthetic stream or a background-playback exemption.
bool _isRealDeviceAccess(SitePermissionBadge badge) =>
    badge == SitePermissionBadge.realLocation ||
    badge == SitePermissionBadge.realCamera;

/// Filled glyph for a real device, outlined for a synthetic stream.
IconData sitePermissionBadgeIcon(SitePermissionBadge badge) => switch (badge) {
      SitePermissionBadge.realLocation => Icons.location_on,
      SitePermissionBadge.spoofLocation => Icons.location_on_outlined,
      SitePermissionBadge.realCamera => Icons.videocam,
      SitePermissionBadge.virtualCamera => Icons.videocam_outlined,
      SitePermissionBadge.virtualMicrophone => Icons.mic_none,
      SitePermissionBadge.virtualScreenShare => Icons.screen_share_outlined,
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
    SitePermissionBadge.virtualMicrophone =>
      '${loc.siteSettingsMicrophoneAccess}$separator${loc.siteSettingsMicrophoneAccessVirtual}',
    SitePermissionBadge.virtualScreenShare =>
      '${loc.siteSettingsScreenShare}$separator${loc.siteSettingsScreenShareVirtual}',
    SitePermissionBadge.backgroundAudio => loc.siteSettingsBackgroundAudio,
  };
}

/// Row of permission badges for [model], or an empty box when the site holds
/// none. Sized for the drawer's site tiles: [iconSize] defaults to the
/// smallest legible glyph, and [overlay] paints a scrim so the strip stays
/// readable on top of a favicon.
class SitePermissionBadges extends StatelessWidget {
  const SitePermissionBadges({
    super.key,
    required this.model,
    this.iconSize = 10,
    this.overlay = false,
  });

  final WebViewModel model;
  final double iconSize;
  final bool overlay;

  @override
  Widget build(BuildContext context) {
    final badges = sitePermissionBadges(model);
    if (badges.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context);
    final strip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // No Tooltip: the strip sits inside the drawer tile's long-press
        // gestures (context menu, drag-to-reorder) and must not compete for
        // them. The label rides `semanticLabel` instead.
        for (final badge in badges)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: iconSize * 0.05),
            child: Icon(
              sitePermissionBadgeIcon(badge),
              size: iconSize,
              semanticLabel: sitePermissionBadgeLabel(loc, badge),
              color: _isRealDeviceAccess(badge)
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );

    if (!overlay) return strip;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: iconSize * 0.2, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(iconSize),
      ),
      child: strip,
    );
  }
}
