import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/services/virtual_media_picker.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/settings/site_permission_state.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/site_permission_badges.dart';
import 'package:webspace/widgets/site_permission_chip.dart';
import 'package:webspace/widgets/virtual_source_preview.dart';

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
    required this.archived,
    required this.captures,
    required this.notificationsEnabled,
    required this.backgroundAudioEnabled,
    required this.protectedContentAllowed,
    required this.locationMode,
    required this.liveLocationGranularity,
    required this.hasStaticCoordinates,
    required this.spoofTimezone,
    required this.spoofTimezoneFromLocation,
  });

  /// Not edited here: an archive-tier site is held to the archive's posture
  /// for every capability ARCH-006 folds.
  final bool archived;
  final CaptureGrants captures;
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
    CaptureGrants? captures,
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
        archived: archived,
        captures: captures ?? this.captures,
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

  /// What the site runs with, which is what the screen and the settings row
  /// show; the stored values survive underneath for when it leaves the
  /// archive.
  CaptureGrants get effectiveCaptures =>
      ArchiveFold.captures(captures, archived: archived);
  bool get effectiveNotifications =>
      ArchiveFold.notifications(notificationsEnabled, archived: archived);
  bool get effectiveBackgroundAudio =>
      ArchiveFold.backgroundAudio(backgroundAudioEnabled, archived: archived);
  bool? effectiveProtectedContent({required bool trackingProtection}) =>
      resolveProtectedContent(protectedContentAllowed,
          archived: archived, trackingProtection: trackingProtection);
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
  /// than omitted: for screen sharing, the absent "Allowed" row *is* the
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

  /// Picks [kind]'s file; a picked one becomes the site's source, a rejected
  /// one is named in a SnackBar, and a cancelled pick changes nothing.
  Future<void> _pickSource<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
  ) async {
    final result = await VirtualMediaPicker.pick(kind.medium);
    if (!mounted) return;
    if (result.source case final source?) {
      final grant = kind.grantOf(_values.captures);
      _setGrant(kind, (mode: grant.mode, source: source));
    } else if (result.error case final error?) {
      _snack(kind.text(AppLocalizations.of(context)).pickError(error));
    }
  }

  void _setGrant<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
    CaptureGrant<M, S> grant,
  ) => _update(
    _values.copyWith(captures: kind.withGrant(_values.captures, grant)),
  );

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Capability descriptors ---------------------------------------------

  String? _archiveReason(AppLocalizations loc) =>
      _values.archived ? loc.settingLockedByArchive : null;

  /// One option per mode, listed in the order the states read.
  static List<_Option> _optionsOf<T extends Enum>(
    List<T> modes, {
    required SitePermissionState Function(T mode) state,
    required String Function(T mode) label,
    required void Function(T mode) select,
    List<_Option> unavailable = const [],
  }) =>
      [
        for (final m in modes)
          _Option(state: state(m), label: label(m), onSelect: () => select(m)),
        ...unavailable,
      ]..sort((a, b) => a.state.index.compareTo(b.state.index));

  Future<void> _selectCapture<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
    M mode,
  ) async {
    final source = kind.grantOf(_values.captures).source;
    _setGrant(kind, (mode: mode, source: source));
    if (mode == kind.virtual && source == null) await _pickSource(kind);
  }

  Future<void> _pickCoordinates() async {
    if (await widget.onOpenLocationPicker()) {
      _update(_values.copyWith(hasStaticCoordinates: true));
    }
  }

  Future<void> _selectLocation(LocationMode m) async {
    _update(_values.copyWith(locationMode: m));
    if (m == LocationMode.spoof && !_values.hasStaticCoordinates) {
      await _pickCoordinates();
    }
  }

  _Capability _capture<M extends CaptureMode, S extends VirtualSource>(
    CaptureKind<M, S> kind,
  ) {
    final loc = AppLocalizations.of(context);
    final text = kind.text(loc);
    final stored = kind.grantOf(_values.captures);
    final state = kind.grantOf(_values.effectiveCaptures).mode.state;
    return _Capability(
      icon: kind.icon(real: opensRealDevice(state)),
      title: text.title,
      hint: text.hint,
      state: state,
      lockedReason: _archiveReason(loc),
      qualifier: stored.mode == kind.virtual
          ? (stored.source?.fileName ?? text.noSource)
          : null,
      options: _optionsOf(
        kind.modes,
        state: (mode) => mode.state,
        label: (mode) => mode.label(loc),
        select: (mode) => _selectCapture(kind, mode),
        unavailable: [
          if (kind.real == null)
            _Option(
              state: SitePermissionState.allowed,
              label: loc.permissionStateAllowed,
              onSelect: () {},
              enabled: false,
              unavailableReason: text.neverReal,
            ),
        ],
      ),
      detail: (context, setSheetState) {
        final grant = kind.grantOf(_values.captures);
        if (grant.mode != kind.virtual) return const SizedBox.shrink();
        return _sourceDetail(
          fileName: grant.source?.fileName,
          emptyLabel: text.noSource,
          actionLabel: text.chooseSource,
          icon: switch (kind.medium) {
            CaptureMedium.visual => Icons.photo_library_outlined,
            CaptureMedium.audio => Icons.audiotrack_outlined,
          },
          onPick: () async {
            await _pickSource(kind);
            setSheetState(() {});
          },
          preview: switch (grant.source) {
            final VirtualVisualSource source => VirtualSourcePreview(
              source: source,
              aspectRatio: kind.previewFrame.aspectRatio,
              fit: kind.previewFrame.fit,
            ),
            VirtualAudioSource() || null => null,
          },
        );
      },
    );
  }

  _Capability _location(AppLocalizations loc) => _Capability(
        icon: _values.locationMode == LocationMode.live
            ? Icons.my_location
            : Icons.location_on_outlined,
        title: loc.siteSettingsGeolocation,
        hint: loc.siteSettingsGeolocationHint,
        state: locationPermissionState(_values.locationMode),
        qualifier: switch (_values.locationMode) {
          LocationMode.live => _values.liveLocationGranularity.description(loc),
          LocationMode.spoof => _values.hasStaticCoordinates
              ? widget.coordinatesPreview()
              : loc.siteSettingsLocationNoneSet,
          LocationMode.off => null,
        },
        options: _optionsOf(
          LocationMode.values,
          state: locationPermissionState,
          label: (m) => m.label(loc),
          select: _selectLocation,
        ),
        detail: (context, setSheetState) => switch (_values.locationMode) {
          LocationMode.live => _granularityPicker(loc, setSheetState),
          LocationMode.spoof => _coordinatesDetail(loc, setSheetState),
          LocationMode.off => const SizedBox.shrink(),
        },
        footer: (context, setSheetState) => _timezoneField(loc, setSheetState),
      );

  /// The three granularity tiers are one enum, so they are one control.
  Widget _granularityPicker(AppLocalizations loc, StateSetter setSheetState) =>
      Padding(
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
                title: Text(tier.label(loc)),
                subtitle: Text(tier.description(loc),
                    style: const TextStyle(fontSize: 11)),
                onChanged: (v) {
                  if (v == null) return;
                  _update(_values.copyWith(liveLocationGranularity: v));
                  setSheetState(() {});
                },
              ),
          ],
        ),
      );

  Widget _coordinatesDetail(AppLocalizations loc, StateSetter setSheetState) =>
      Padding(
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
                await _pickCoordinates();
                setSheetState(() {});
              },
            ),
          ],
        ),
      );

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
        state: protectedContentPermissionState(_values.effectiveProtectedContent(
            trackingProtection: widget.trackingProtectionEnabled)),
        lockedReason: _archiveReason(loc) ??
            (widget.trackingProtectionEnabled
                ? loc.siteSettingsProtectedContentBlockedByEtp
                : null),
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
      state: notificationPermissionState(_values.effectiveNotifications),
      qualifier: permissionDenied
          ? loc.siteSettingsNotificationsDenied(settingsPath)
          : null,
      lockedReason: _archiveReason(loc) ??
          (blocked ? loc.siteSettingsNotificationsBlockedByProxy(blockedBy) : null),
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

  Widget _sourceDetail({
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
        for (final kind in CaptureKind.values) kind.open(_capture),
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
          SettingsNote.host(widget.host),
          const Divider(height: 1),
          SettingsSection(loc.permissionsGroupDeviceAccess),
          for (final kind in CaptureKind.values) _row(kind.open(_capture)),
          _row(_location(loc)),
          SettingsNote(loc.permissionsRealDeviceNote),
          SettingsSection(loc.permissionsGroupBackground),
          if (widget.showNotifications) _row(_notifications(loc)),
          SettingTile(
            leading: const Icon(Icons.music_note_outlined),
            title: loc.siteSettingsBackgroundAudio,
            hint: null,
            subtitle: loc.permissionsBackgroundAudioNotAGrant,
            lock: _values.archived ? const ArchiveLock() : null,
            control: Toggle(_values.effectiveBackgroundAudio, (value) async {
              _update(_values.copyWith(backgroundAudioEnabled: value));
              // Android shows a media notification with transport controls for
              // background audio; on Android 13+ that needs POST_NOTIFICATIONS.
              if (value && hostIsAndroid) {
                await NotificationService.instance.requestPermission();
              }
            }),
          ),
          if (hostIsAndroid) ...[
            SettingsSection(loc.permissionsGroupMedia),
            _row(_protectedContent(loc)),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
