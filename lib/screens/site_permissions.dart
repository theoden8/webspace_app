import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/virtual_camera_service.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/services/virtual_microphone_service.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/widgets/site_permission_chip.dart';
import 'package:webspace/widgets/virtual_camera_preview.dart';

/// Everything the permission screen may change, in one value so the caller can
/// apply a whole edit in a single `setState`.
///
/// The screen deliberately owns no persistent state: [SiteSettingsScreen]
/// keeps the fields, the dirty-snapshot diff and the save path exactly as they
/// were, and this is only a different way of presenting them. Moving the
/// fields here instead would have taken them out of that diff, which is how
/// unsaved edits get dropped (BUG-006).
class SitePermissionValues {
  const SitePermissionValues({
    required this.cameraMode,
    required this.virtualCameraSource,
    required this.microphoneMode,
    required this.virtualMicrophoneSource,
    required this.notificationsEnabled,
    required this.backgroundAudioEnabled,
    required this.protectedContentAllowed,
    required this.locationMode,
    required this.liveLocationGranularity,
    required this.hasStaticCoordinates,
    required this.spoofTimezone,
    required this.spoofTimezoneFromLocation,
  });

  final CameraAccessMode cameraMode;
  final VirtualCameraSource? virtualCameraSource;
  final MicrophoneAccessMode microphoneMode;
  final VirtualMicrophoneSource? virtualMicrophoneSource;
  final bool notificationsEnabled;
  final bool backgroundAudioEnabled;
  final bool? protectedContentAllowed;
  final LocationMode locationMode;
  final LocationGranularity liveLocationGranularity;

  /// Whether static coordinates are set. The coordinates themselves stay with
  /// the caller's text controllers; the screen only needs to know if picking
  /// one is still outstanding.
  final bool hasStaticCoordinates;

  /// IANA zone reported to the page, or null for the system default. Sits with
  /// location rather than beside the user agent because it is the same
  /// disclosure: a zone pins a site's guess at where you are to a region, and
  /// `spoofTimezoneFromLocation` derives it from the very coordinates chosen
  /// one control above.
  final String? spoofTimezone;
  final bool spoofTimezoneFromLocation;

  SitePermissionValues copyWith({
    CameraAccessMode? cameraMode,
    VirtualCameraSource? virtualCameraSource,
    bool clearVirtualCameraSource = false,
    MicrophoneAccessMode? microphoneMode,
    VirtualMicrophoneSource? virtualMicrophoneSource,
    bool clearVirtualMicrophoneSource = false,
    bool? notificationsEnabled,
    bool? backgroundAudioEnabled,
    bool? protectedContentAllowed,
    bool clearProtectedContentAllowed = false,
    LocationMode? locationMode,
    LocationGranularity? liveLocationGranularity,
    bool? hasStaticCoordinates,
    String? spoofTimezone,
    bool clearSpoofTimezone = false,
    bool? spoofTimezoneFromLocation,
  }) =>
      SitePermissionValues(
        cameraMode: cameraMode ?? this.cameraMode,
        virtualCameraSource: clearVirtualCameraSource
            ? null
            : (virtualCameraSource ?? this.virtualCameraSource),
        microphoneMode: microphoneMode ?? this.microphoneMode,
        virtualMicrophoneSource: clearVirtualMicrophoneSource
            ? null
            : (virtualMicrophoneSource ?? this.virtualMicrophoneSource),
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        backgroundAudioEnabled:
            backgroundAudioEnabled ?? this.backgroundAudioEnabled,
        protectedContentAllowed: clearProtectedContentAllowed
            ? null
            : (protectedContentAllowed ?? this.protectedContentAllowed),
        locationMode: locationMode ?? this.locationMode,
        liveLocationGranularity:
            liveLocationGranularity ?? this.liveLocationGranularity,
        hasStaticCoordinates: hasStaticCoordinates ?? this.hasStaticCoordinates,
        spoofTimezone:
            clearSpoofTimezone ? null : (spoofTimezone ?? this.spoofTimezone),
        spoofTimezoneFromLocation:
            spoofTimezoneFromLocation ?? this.spoofTimezoneFromLocation,
      );
}

/// One capability, as the screen renders it. Building rows and sheets from a
/// single descriptor is what keeps every capability the same shape: adding one
/// later means adding a descriptor, not a new idiom.
class _Capability {
  const _Capability({
    required this.icon,
    required this.title,
    required this.hint,
    required this.state,
    required this.options,
    this.qualifier,
    this.lockedReason,
    this.detail,
    this.footer,
  });

  final IconData icon;
  final String title;

  /// Existing per-capability hint copy, shown as the sheet's explanatory body.
  /// Reusing it rather than writing per-state prose keeps one description of
  /// each capability, already reviewed by translators.
  final String hint;

  final SitePermissionState state;
  final List<_Option> options;

  /// Second line on the row, only where the state alone is ambiguous: which
  /// file is being served, how precise a live fix is.
  final String? qualifier;

  /// Set when another setting has taken this capability over. The row is
  /// inert and says why, rather than hiding.
  final String? lockedReason;

  /// Extra controls under the selected option in the sheet (source picker,
  /// preview, precision).
  final Widget Function(BuildContext, StateSetter)? detail;

  /// Controls shown once at the foot of the sheet, below every option. For
  /// settings that belong to the capability as a whole rather than to one of
  /// its states.
  final Widget Function(BuildContext, StateSetter)? footer;
}

class _Option {
  const _Option({
    required this.state,
    required this.label,
    required this.onSelect,
    this.enabled = true,
    this.unavailableReason,
  });

  final SitePermissionState state;
  final String label;
  final VoidCallback onSelect;

  /// A state this capability structurally cannot reach. Shown greyed rather
  /// than omitted: for the microphone, the absent "Allowed" row *is* the
  /// guarantee, and hiding it would hide the reassurance.
  final bool enabled;
  final String? unavailableReason;
}

/// Per-site permission screen: every capability a site can reach, one row
/// each, in the order a reader thinks about them.
class SitePermissionsScreen extends StatefulWidget {
  const SitePermissionsScreen({
    super.key,
    required this.host,
    required this.values,
    required this.onChanged,
    required this.onOpenLocationPicker,
    required this.onEnableNotifications,
    required this.timezonePreview,
    required this.coordinatesPreview,
    this.trackingProtectionEnabled = false,
    this.notificationsBlockedBySite,
    this.showNotifications = true,
  });

  final String host;
  final SitePermissionValues values;
  final ValueChanged<SitePermissionValues> onChanged;

  /// Opens the caller's location picker and reports whether coordinates were
  /// set. The picker writes through to the caller's own controllers, which is
  /// where the coordinates live.
  final Future<bool> Function() onOpenLocationPicker;

  /// Runs the caller's enable-notifications flow: the one-time background
  /// limits dialog, then the OS permission request. Kept with the caller so
  /// this screen does not import the one that pushes it.
  final Future<void> Function() onEnableNotifications;

  /// What the timezone dataset resolves the caller's current coordinates to,
  /// read on every rebuild rather than passed as a value: coordinates can be
  /// picked from inside this screen, and a snapshot taken at push time would
  /// go stale the moment they are.
  final String Function() timezonePreview;

  /// The picked static coordinates, formatted for display, or null when none
  /// are set. Read on every rebuild for the same reason as [timezonePreview]:
  /// they can be picked from inside this screen. Naming them is what makes a
  /// Simulated location row as informative as a Simulated camera row, which
  /// names the file it serves.
  final String? Function() coordinatesPreview;

  /// Tracking protection forces protected content off while it is on, and
  /// forces the timezone to follow picked coordinates so the spoofed
  /// Date/Intl values agree with the spoofed geo.
  final bool trackingProtectionEnabled;

  /// Android: another site is already polling in the background under a
  /// different proxy, so notifications cannot be enabled here.
  final String? notificationsBlockedBySite;

  /// Notifications need container support; hidden entirely without it, as the
  /// settings screen did.
  final bool showNotifications;

  @override
  State<SitePermissionsScreen> createState() => _SitePermissionsScreenState();
}

class _SitePermissionsScreenState extends State<SitePermissionsScreen> {
  late SitePermissionValues _values = widget.values;

  void _update(SitePermissionValues next) {
    setState(() => _values = next);
    widget.onChanged(next);
  }

  Future<void> _pickCameraSource() async {
    final result = await VirtualCameraService.pickSource();
    if (!mounted) return;
    if (result.source != null) {
      _update(_values.copyWith(virtualCameraSource: result.source));
      return;
    }
    if (result.error == null) return; // user cancelled
    final loc = AppLocalizations.of(context);
    _snack(switch (result.error!) {
      VirtualMediaPickError.tooLarge => loc.homeCameraSourceTooLarge,
      VirtualMediaPickError.type ||
      VirtualMediaPickError.read =>
        loc.homeCameraSourceError,
    });
  }

  Future<void> _pickMicrophoneSource() async {
    final result = await VirtualMicrophoneService.pickSource();
    if (!mounted) return;
    if (result.source != null) {
      _update(_values.copyWith(virtualMicrophoneSource: result.source));
      return;
    }
    if (result.error == null) return;
    final loc = AppLocalizations.of(context);
    _snack(switch (result.error!) {
      VirtualMediaPickError.tooLarge => loc.homeMicrophoneSourceTooLarge,
      VirtualMediaPickError.type ||
      VirtualMediaPickError.read =>
        loc.homeMicrophoneSourceError,
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Capability descriptors ---------------------------------------------

  _Capability _camera(AppLocalizations loc) => _Capability(
        icon: _values.cameraMode == CameraAccessMode.real
            ? Icons.videocam
            : Icons.videocam_outlined,
        title: loc.siteSettingsCameraAccess,
        hint: loc.siteSettingsCameraAccessHint,
        state: cameraPermissionState(_values.cameraMode),
        qualifier: _values.cameraMode == CameraAccessMode.virtual
            ? (_values.virtualCameraSource?.fileName ??
                loc.siteSettingsCameraAccessNoSource)
            : null,
        options: [
          _Option(
            state: SitePermissionState.ask,
            label: loc.siteSettingsCameraAccessAsk,
            onSelect: () =>
                _update(_values.copyWith(cameraMode: CameraAccessMode.ask)),
          ),
          _Option(
            state: SitePermissionState.allowed,
            label: loc.siteSettingsCameraAccessAllow,
            onSelect: () =>
                _update(_values.copyWith(cameraMode: CameraAccessMode.real)),
          ),
          _Option(
            state: SitePermissionState.simulated,
            label: loc.siteSettingsCameraAccessVirtual,
            onSelect: () async {
              _update(
                  _values.copyWith(cameraMode: CameraAccessMode.virtual));
              if (_values.virtualCameraSource == null) {
                await _pickCameraSource();
              }
            },
          ),
          _Option(
            state: SitePermissionState.blocked,
            label: loc.siteSettingsCameraAccessBlock,
            onSelect: () =>
                _update(_values.copyWith(cameraMode: CameraAccessMode.block)),
          ),
        ],
        detail: (context, setSheetState) {
          if (_values.cameraMode != CameraAccessMode.virtual) {
            return const SizedBox.shrink();
          }
          return _sourceDetail(
            loc,
            fileName: _values.virtualCameraSource?.fileName,
            emptyLabel: loc.siteSettingsCameraAccessNoSource,
            actionLabel: loc.siteSettingsCameraAccessChooseSource,
            icon: Icons.photo_library_outlined,
            onPick: () async {
              await _pickCameraSource();
              setSheetState(() {});
            },
            preview: _values.virtualCameraSource == null
                ? null
                : VirtualCameraPreview(source: _values.virtualCameraSource!),
          );
        },
      );

  _Capability _microphone(AppLocalizations loc) => _Capability(
        icon: Icons.mic_none,
        title: loc.siteSettingsMicrophoneAccess,
        hint: loc.siteSettingsMicrophoneAccessHint,
        state: microphonePermissionState(_values.microphoneMode),
        qualifier: _values.microphoneMode == MicrophoneAccessMode.virtual
            ? (_values.virtualMicrophoneSource?.fileName ??
                loc.siteSettingsMicrophoneAccessNoSource)
            : null,
        options: [
          _Option(
            state: SitePermissionState.ask,
            label: loc.siteSettingsMicrophoneAccessAsk,
            onSelect: () => _update(
                _values.copyWith(microphoneMode: MicrophoneAccessMode.ask)),
          ),
          // Shown, not omitted: the unavailable row is where the "no real
          // microphone, ever" guarantee becomes visible. Today it is buried in
          // a hint popup.
          _Option(
            state: SitePermissionState.allowed,
            label: loc.permissionStateAllowed,
            onSelect: () {},
            enabled: false,
            unavailableReason: loc.permissionMicrophoneNeverReal,
          ),
          _Option(
            state: SitePermissionState.simulated,
            label: loc.siteSettingsMicrophoneAccessVirtual,
            onSelect: () async {
              _update(_values.copyWith(
                  microphoneMode: MicrophoneAccessMode.virtual));
              if (_values.virtualMicrophoneSource == null) {
                await _pickMicrophoneSource();
              }
            },
          ),
          _Option(
            state: SitePermissionState.blocked,
            label: loc.siteSettingsMicrophoneAccessBlock,
            onSelect: () => _update(
                _values.copyWith(microphoneMode: MicrophoneAccessMode.block)),
          ),
        ],
        detail: (context, setSheetState) {
          if (_values.microphoneMode != MicrophoneAccessMode.virtual) {
            return const SizedBox.shrink();
          }
          return _sourceDetail(
            loc,
            fileName: _values.virtualMicrophoneSource?.fileName,
            emptyLabel: loc.siteSettingsMicrophoneAccessNoSource,
            actionLabel: loc.siteSettingsMicrophoneAccessChooseSource,
            icon: Icons.audiotrack_outlined,
            onPick: () async {
              await _pickMicrophoneSource();
              setSheetState(() {});
            },
          );
        },
      );

  _Capability _location(AppLocalizations loc) {
    final granularityText = switch (_values.liveLocationGranularity) {
      LocationGranularity.gps => loc.siteSettingsLocationGranularityGps,
      LocationGranularity.approximate =>
        loc.siteSettingsLocationGranularityApproximate,
      LocationGranularity.gsm => loc.siteSettingsLocationGranularityGsm,
    };
    return _Capability(
      icon: _values.locationMode == LocationMode.live
          ? Icons.my_location
          : Icons.location_on_outlined,
      title: loc.siteSettingsGeolocation,
      hint: loc.siteSettingsGeolocationHint,
      state: locationPermissionState(_values.locationMode),
      qualifier: switch (_values.locationMode) {
        LocationMode.live => granularityText,
        LocationMode.spoof => _values.hasStaticCoordinates
            ? widget.coordinatesPreview()
            : loc.siteSettingsLocationNoneSet,
        LocationMode.off => null,
      },
      options: [
        _Option(
          state: SitePermissionState.allowed,
          label: loc.siteSettingsLocationLive,
          onSelect: () =>
              _update(_values.copyWith(locationMode: LocationMode.live)),
        ),
        _Option(
          state: SitePermissionState.simulated,
          label: loc.siteSettingsLocationStatic,
          onSelect: () async {
            _update(_values.copyWith(locationMode: LocationMode.spoof));
            if (!_values.hasStaticCoordinates) {
              final picked = await widget.onOpenLocationPicker();
              if (picked) {
                _update(_values.copyWith(hasStaticCoordinates: true));
              }
            }
          },
        ),
        _Option(
          state: SitePermissionState.blocked,
          label: loc.siteSettingsLocationOff,
          onSelect: () =>
              _update(_values.copyWith(locationMode: LocationMode.off)),
        ),
      ],
      detail: (context, setSheetState) {
        if (_values.locationMode == LocationMode.live) {
          // The three granularity tiers are one enum, so they are one control.
          // The settings screen spelled them as a GPS/GSM segmented button
          // plus an "Approximate" switch that silently overlapped it.
          return Padding(
            padding: const EdgeInsets.only(left: 32, top: 4, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final tier in LocationGranularity.values)
                  RadioListTile<LocationGranularity>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: tier,
                    groupValue: _values.liveLocationGranularity,
                    title: Text(switch (tier) {
                      LocationGranularity.gps =>
                        loc.siteSettingsLocationProviderGps,
                      LocationGranularity.approximate =>
                        loc.siteSettingsLocationApproximate,
                      LocationGranularity.gsm =>
                        loc.siteSettingsLocationProviderGsm,
                    }),
                    subtitle: Text(
                      switch (tier) {
                        LocationGranularity.gps =>
                          loc.siteSettingsLocationGranularityGps,
                        LocationGranularity.approximate =>
                          loc.siteSettingsLocationGranularityApproximate,
                        LocationGranularity.gsm =>
                          loc.siteSettingsLocationGranularityGsm,
                      },
                      style: const TextStyle(fontSize: 11),
                    ),
                    onChanged: (v) {
                      if (v == null) return;
                      _update(_values.copyWith(liveLocationGranularity: v));
                      setSheetState(() {});
                    },
                  ),
              ],
            ),
          );
        }
        if (_values.locationMode == LocationMode.spoof) {
          return Padding(
            padding: const EdgeInsets.only(left: 32, top: 8, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    (_values.hasStaticCoordinates
                            ? widget.coordinatesPreview()
                            : null) ??
                        loc.siteSettingsLocationNoneSet,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(loc.siteSettingsLocationPick),
                  onPressed: () async {
                    final picked = await widget.onOpenLocationPicker();
                    if (picked) {
                      _update(_values.copyWith(hasStaticCoordinates: true));
                    }
                    setSheetState(() {});
                  },
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
      footer: (context, setSheetState) => _timezoneField(loc, setSheetState),
    );
  }

  /// Sentinel for the "From picked location" entry. Not a real IANA name;
  /// translated to and from `spoofTimezoneFromLocation` when read and written.
  static const String _kFromLocationSentinel = '__from_location__';

  /// Render a timezone entry. The `null` (System default) entry is enriched
  /// with the device's current abbreviation/offset and local time, so the user
  /// can see what "default" actually entails.
  String _timezoneLabel(MapEntry<String?, String> entry) {
    if (entry.key != null) return entry.value;
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.abs().inHours.toString().padLeft(2, '0');
    final minutes = (offset.abs().inMinutes % 60).toString().padLeft(2, '0');
    final clock = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return '${entry.value} (${now.timeZoneName} $sign$hours:$minutes, $clock)';
  }

  Widget _timezoneField(AppLocalizations loc, StateSetter setSheetState) {
    final preview = widget.timezonePreview();

    // Tracking Protection forces the timezone to follow picked coordinates so
    // the spoofed Date/Intl values match the spoofed geo. With no coordinates
    // the umbrella does NOT touch the timezone: the user's stored choice (or
    // the system default) stands.
    final forceFromLocation =
        widget.trackingProtectionEnabled && _values.hasStaticCoordinates;
    final String? value = (forceFromLocation || _values.spoofTimezoneFromLocation)
        ? _kFromLocationSentinel
        : (commonTimezones.any((e) => e.key == _values.spoofTimezone)
            ? _values.spoofTimezone
            : null);

    // "From picked location" is conceptually a sibling of "System default":
    // both derive the zone instead of taking an explicit one, so it goes
    // directly after that entry rather than at the bottom of the list.
    final items = <DropdownMenuItem<String?>>[];
    var insertedFromLocation = false;
    for (final e in commonTimezones) {
      items.add(DropdownMenuItem<String?>(
        value: e.key,
        child: Text(_timezoneLabel(e)),
      ));
      if (!insertedFromLocation && e.key == null) {
        items.add(DropdownMenuItem<String?>(
          value: _kFromLocationSentinel,
          child: Text(loc.siteSettingsTimezoneFromLocation(preview)),
        ));
        insertedFromLocation = true;
      }
    }
    // Defensive fallback: if commonTimezones ever loses the System default
    // entry, still expose the option somewhere.
    if (!insertedFromLocation) {
      items.insert(
        0,
        DropdownMenuItem<String?>(
          value: _kFromLocationSentinel,
          child: Text(loc.siteSettingsTimezoneFromLocation(preview)),
        ),
      );
    }

    return DropdownButtonFormField<String?>(
      value: value,
      decoration: InputDecoration(
        labelText: loc.siteSettingsTimezoneLabel,
        helperText: forceFromLocation
            ? loc.siteSettingsTimezoneForcedHelper
            : loc.siteSettingsTimezoneHelper,
        border: const OutlineInputBorder(),
      ),
      items: items,
      isExpanded: true,
      onChanged: forceFromLocation
          ? null
          : (v) {
              if (v == _kFromLocationSentinel) {
                _update(_values.copyWith(
                    spoofTimezoneFromLocation: true, clearSpoofTimezone: true));
              } else {
                _update(_values.copyWith(
                    spoofTimezoneFromLocation: false,
                    spoofTimezone: v,
                    clearSpoofTimezone: v == null));
              }
              setSheetState(() {});
            },
    );
  }

  _Capability _protectedContent(AppLocalizations loc) => _Capability(
        icon: Icons.shield_outlined,
        title: loc.siteSettingsProtectedContent,
        hint: loc.siteSettingsProtectedContentHint,
        state: widget.trackingProtectionEnabled
            ? SitePermissionState.blocked
            : protectedContentPermissionState(_values.protectedContentAllowed),
        lockedReason: widget.trackingProtectionEnabled
            ? loc.siteSettingsProtectedContentBlockedByEtp
            : null,
        options: [
          _Option(
            state: SitePermissionState.ask,
            label: loc.siteSettingsProtectedContentAsk,
            onSelect: () => _update(
                _values.copyWith(clearProtectedContentAllowed: true)),
          ),
          _Option(
            state: SitePermissionState.allowed,
            label: loc.siteSettingsProtectedContentAllow,
            onSelect: () =>
                _update(_values.copyWith(protectedContentAllowed: true)),
          ),
          _Option(
            state: SitePermissionState.blocked,
            label: loc.siteSettingsProtectedContentBlock,
            onSelect: () =>
                _update(_values.copyWith(protectedContentAllowed: false)),
          ),
        ],
      );

  _Capability _notifications(AppLocalizations loc) {
    final blockedBy = widget.notificationsBlockedBySite;
    // The conflict gate only forbids enabling. An already-on toggle can still
    // be turned off; we just do not let it flip back while the conflict holds.
    final blocked = blockedBy != null && !_values.notificationsEnabled;
    final permissionDenied = _values.notificationsEnabled &&
        NotificationService.instance.permissionGranted == false;
    final settingsPath =
        hostIsIOS ? 'Notifications → WebSpace' : 'WebSpace → Notifications';
    return _Capability(
      icon: Icons.notifications_none,
      title: loc.siteSettingsNotifications,
      hint: loc.siteSettingsNotificationsHint,
      state: notificationPermissionState(_values.notificationsEnabled),
      qualifier: permissionDenied
          ? loc.siteSettingsNotificationsDenied(settingsPath)
          : null,
      lockedReason:
          blocked ? loc.siteSettingsNotificationsBlockedByProxy(blockedBy) : null,
      options: [
        _Option(
          state: SitePermissionState.allowed,
          label: loc.siteSettingsProtectedContentAllow,
          onSelect: () async {
            _update(_values.copyWith(notificationsEnabled: true));
            await widget.onEnableNotifications();
          },
        ),
        _Option(
          state: SitePermissionState.blocked,
          label: loc.siteSettingsProtectedContentBlock,
          onSelect: () =>
              _update(_values.copyWith(notificationsEnabled: false)),
        ),
      ],
    );
  }

  // --- Rendering -----------------------------------------------------------

  Widget _sourceDetail(
    AppLocalizations loc, {
    required String? fileName,
    required String emptyLabel,
    required String actionLabel,
    required IconData icon,
    required Future<void> Function() onPick,
    Widget? preview,
  }) =>
      Padding(
        padding: const EdgeInsets.only(left: 32, top: 4, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fileName ?? emptyLabel,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                TextButton.icon(
                  icon: Icon(icon, size: 18),
                  label: Text(actionLabel),
                  onPressed: onPick,
                ),
              ],
            ),
            if (preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: preview,
              ),
          ],
        ),
      );

  Widget _groupHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _row(_Capability capability) {
    final scheme = Theme.of(context).colorScheme;
    final locked = capability.lockedReason != null;
    final subtitle = capability.lockedReason ?? capability.qualifier;
    return Opacity(
      opacity: locked ? 0.55 : 1.0,
      child: ListTile(
        leading: Icon(
          capability.icon,
          color: opensRealDevice(capability.state) ? scheme.error : null,
        ),
        title: Text(capability.title, style: const TextStyle(fontSize: 15.5)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: const TextStyle(fontSize: 12.5)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SitePermissionChip(state: capability.state, dimmed: locked),
            if (!locked) const Icon(Icons.chevron_right, size: 18),
          ],
        ),
        onTap: locked ? null : () => _openSheet(capability),
      ),
    );
  }

  Future<void> _openSheet(_Capability capability) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            final loc = AppLocalizations.of(context);
            // Rebuild the descriptor each frame so the sheet reflects edits
            // made inside it.
            final current = _capabilities(loc)
                .firstWhere((c) => c.title == capability.title);
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: Icon(current.icon),
                      title: Text(
                        current.title,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(widget.host),
                      trailing: SitePermissionChip(state: current.state),
                    ),
                    const Divider(height: 1),
                    for (final option in current.options) ...[
                      RadioListTile<SitePermissionState>(
                        value: option.state,
                        groupValue: current.state,
                        title: Text(option.label),
                        subtitle: option.unavailableReason == null
                            ? null
                            : Text(option.unavailableReason!,
                                style: const TextStyle(fontSize: 12)),
                        onChanged: option.enabled
                            ? (_) {
                                option.onSelect();
                                setSheetState(() {});
                              }
                            : null,
                      ),
                      if (option.state == current.state &&
                          current.detail != null)
                        current.detail!(context, setSheetState),
                    ],
                    if (current.footer != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: current.footer!(context, setSheetState),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          current.hint,
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

  List<_Capability> _capabilities(AppLocalizations loc) => [
        _camera(loc),
        _microphone(loc),
        _location(loc),
        if (widget.showNotifications) _notifications(loc),
        _protectedContent(loc),
      ];

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.permissionsTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              widget.host,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          _groupHeader(loc.permissionsGroupDeviceAccess),
          _row(_camera(loc)),
          _row(_microphone(loc)),
          _row(_location(loc)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              loc.permissionsRealDeviceNote,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _groupHeader(loc.permissionsGroupBackground),
          if (widget.showNotifications) _row(_notifications(loc)),
          SwitchListTile(
            secondary: const Icon(Icons.music_note_outlined),
            title: Text(loc.siteSettingsBackgroundAudio,
                style: const TextStyle(fontSize: 15.5)),
            subtitle: Text(loc.permissionsBackgroundAudioNotAGrant,
                style: const TextStyle(fontSize: 12.5)),
            value: _values.backgroundAudioEnabled,
            onChanged: (value) async {
              _update(_values.copyWith(backgroundAudioEnabled: value));
              // Android shows a media notification with transport controls for
              // background audio; on Android 13+ that needs POST_NOTIFICATIONS.
              if (value && hostIsAndroid) {
                await NotificationService.instance.requestPermission();
              }
            },
          ),
          if (hostIsAndroid) ...[
            _groupHeader(loc.permissionsGroupMedia),
            _row(_protectedContent(loc)),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
