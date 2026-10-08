import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/web_view_model.dart';

/// A permission or background capability a site currently holds, surfaced as
/// a badge on the drawer tile so the grant is visible without opening
/// per-site settings. Covers every grant the site's Permissions row counts as
/// held, plus background audio.
///
/// Only settled grants appear: `ask` (undecided), `block` and
/// [LocationMode.off] produce no badge. A simulated grant (a spoofed location,
/// a picked file in place of a device) feeds the site data with no device
/// opened and renders muted, so a glance separates "this site can see/hear
/// the room" from "this site is being played a file".
sealed class SitePermissionBadge {}

/// A capture kind held at a [mode] that reaches the page: the device itself
/// (the camera and microphone's `real`, MIC-014) or a picked file.
final class CaptureBadge implements SitePermissionBadge {
  const CaptureBadge(this.kind, this.mode);

  final CaptureKind kind;
  final CaptureMode mode;

  @override
  bool operator ==(Object other) =>
      other is CaptureBadge && other.kind == kind && other.mode == mode;

  @override
  int get hashCode => Object.hash(kind, mode);
}

enum GrantBadge implements SitePermissionBadge {
  /// [LocationMode.live]: the real device fix reaches the page (at the
  /// site's [LocationGranularity]).
  realLocation,

  /// [LocationMode.spoof]: pages get user-picked coordinates.
  spoofLocation,

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

extension CaptureKindIcon on CaptureKind {
  /// Filled for a real device, outlined for a picked file.
  IconData icon({required bool real}) => switch (this) {
    CaptureKind.camera => real ? Icons.videocam : Icons.videocam_outlined,
    CaptureKind.microphone => real ? Icons.mic : Icons.mic_none,
    CaptureKind.screenShare =>
      real ? Icons.screen_share : Icons.screen_share_outlined,
  };
}

/// What a site runs with, the archive and Tracking Protection applied: the
/// one input the drawer's badges and the settings' Permissions row share, so
/// the row cannot list a grant the drawer does not badge (PERMBADGE-001).
typedef HeldGrants = ({
  LocationMode location,
  CaptureGrants captures,
  bool notifications,
  bool protectedContent,
  bool backgroundAudio,
});

/// Badges for [held], in a stable display order (the Permissions row's
/// order, then background playback).
List<SitePermissionBadge> heldBadges(HeldGrants held) => [
  switch (held.location) {
    LocationMode.live => GrantBadge.realLocation,
    LocationMode.spoof => GrantBadge.spoofLocation,
    LocationMode.off => null,
  },
  for (final kind in CaptureKind.values)
    if (kind.grantOf(held.captures).mode case final mode
        when mode.state == SitePermissionState.allowed ||
            mode.state == SitePermissionState.simulated)
      CaptureBadge(kind, mode),
  if (held.notifications) GrantBadge.notifications,
  if (held.protectedContent) GrantBadge.protectedContent,
  if (held.backgroundAudio) GrantBadge.backgroundAudio,
].nonNulls.toList();

/// Badges held by [model]. Reads the `effective*` getters, so an archive-tier
/// site shows no badge even when the stored mode says otherwise (ARCH-006).
/// [protectedContentApplies] defaults to the host check the Permissions row
/// uses.
List<SitePermissionBadge> sitePermissionBadges(
  WebViewModel model, {
  bool? protectedContentApplies,
}) => heldBadges((
  location: model.locationMode,
  captures: model.effectiveCaptures,
  notifications: model.effectiveNotificationsEnabled,
  protectedContent: (protectedContentApplies ?? hostIsAndroid) &&
      model.effectiveProtectedContentAllowed == true,
  backgroundAudio: model.effectiveBackgroundAudioEnabled,
));

/// True when the badge means a real device or capability is handed to the
/// site, as opposed to a synthetic stream or a background-playback exemption.
/// Matches the Permissions row, which draws the same grants in the error
/// colour.
bool isRealDeviceAccess(SitePermissionBadge badge) => switch (badge) {
  CaptureBadge(:final mode) => opensRealDevice(mode.state),
  GrantBadge.realLocation ||
  GrantBadge.notifications ||
  GrantBadge.protectedContent => true,
  GrantBadge.spoofLocation || GrantBadge.backgroundAudio => false,
};

/// The state the Permissions row names a held grant by.
SitePermissionState sitePermissionBadgeState(SitePermissionBadge badge) =>
    switch (badge) {
      CaptureBadge(:final mode) => mode.state,
      GrantBadge.spoofLocation => SitePermissionState.simulated,
      GrantBadge.realLocation ||
      GrantBadge.notifications ||
      GrantBadge.protectedContent ||
      GrantBadge.backgroundAudio => SitePermissionState.allowed,
    };

/// The setting a badge mirrors, as its settings row titles it.
String sitePermissionBadgeTitle(AppLocalizations loc, SitePermissionBadge badge) =>
    switch (badge) {
      CaptureBadge(:final kind) => kind.text(loc).title,
      GrantBadge.realLocation ||
      GrantBadge.spoofLocation => loc.siteSettingsGeolocation,
      GrantBadge.notifications => loc.siteSettingsNotifications,
      GrantBadge.protectedContent => loc.siteSettingsProtectedContent,
      GrantBadge.backgroundAudio => loc.siteSettingsBackgroundAudio,
    };

/// Filled glyph for a real device, outlined for a synthetic stream.
IconData sitePermissionBadgeIcon(SitePermissionBadge badge) => switch (badge) {
  CaptureBadge(:final kind, :final mode) =>
    kind.icon(real: opensRealDevice(mode.state)),
  GrantBadge.realLocation => Icons.location_on,
  GrantBadge.spoofLocation => Icons.location_on_outlined,
  GrantBadge.notifications => Icons.notifications,
  GrantBadge.protectedContent => Icons.shield,
  GrantBadge.backgroundAudio => Icons.music_note,
};

/// Localized "<setting>: <value>" label, e.g. "Camera access: Always allow".
/// Composed from the per-site settings strings the badge mirrors rather than
/// new copy, so the badge and the settings screen can never drift apart.
String sitePermissionBadgeLabel(AppLocalizations loc, SitePermissionBadge badge) {
  const separator = ': ';
  final title = sitePermissionBadgeTitle(loc, badge);
  final value = switch (badge) {
    CaptureBadge(:final mode) => mode.label(loc),
    GrantBadge.realLocation => loc.siteSettingsLocationLive,
    GrantBadge.spoofLocation => loc.siteSettingsLocationStatic,
    GrantBadge.notifications ||
    GrantBadge.protectedContent => loc.siteSettingsProtectedContentAllow,
    GrantBadge.backgroundAudio => null,
  };
  return value == null ? title : '$title$separator$value';
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
            color: isRealDeviceAccess(badge)
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
