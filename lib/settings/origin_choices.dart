import 'package:meta/meta.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/site_permission_state.dart';

/// A capability a page asks for, which a document of another origin inside a
/// site is asked for itself (PERM-002).
enum SitePermission {
  camera(capture: CaptureKind.camera),
  microphone(capture: CaptureKind.microphone),
  screenShare(capture: CaptureKind.screenShare),
  location(capture: null),
  notifications(capture: null),
  protectedContent(capture: null);

  const SitePermission({required this.capture});

  /// The capture kind this is, for the three that are one.
  final CaptureKind? capture;

  static SitePermission ofCapture(CaptureKind kind) =>
      values.firstWhere((p) => p.capture == kind);
}

/// What the user answered each origin other than the site's own, for each
/// capability (PERM-002). It stays on this device: a backup and a QR share
/// leave it out, and an import starts without it.
@immutable
final class OriginChoices {
  const OriginChoices._(this._byPermission);

  static const none = OriginChoices._({});

  final Map<SitePermission, Map<String, bool>> _byPermission;

  /// Whether [origin] was allowed [permission], or null when it was never
  /// asked.
  bool? of(SitePermission permission, {required String origin}) =>
      _byPermission[permission]?[origin];

  /// Every origin answered for [permission], in the order they were asked.
  Map<String, bool> listed(SitePermission permission) =>
      _byPermission[permission] ?? const {};

  bool get isEmpty => _byPermission.isEmpty;

  OriginChoices remember(
    SitePermission permission, {
    required String origin,
    required bool allowed,
  }) => OriginChoices._({
    ..._byPermission,
    permission: {...listed(permission), origin: allowed},
  });

  /// [origin]'s answer for [permission] dropped, or every origin's when
  /// [origin] is null.
  OriginChoices forget(SitePermission permission, {String? origin}) {
    final kept = {
      for (final MapEntry(:key, :value) in listed(permission).entries)
        if (origin != null && key != origin) key: value,
    };
    return OriginChoices._({
      for (final MapEntry(:key, :value) in _byPermission.entries)
        if (key != permission) key: value,
      if (kept.isNotEmpty) permission: kept,
    });
  }

  /// The choices once the site's own [permission] moved [from] one state
  /// [to] another: a move to Block or Ask forgets every origin's answer for
  /// it, so the next one is asked again (PERM-002).
  OriginChoices afterModeChange(
    SitePermission permission, {
    required SitePermissionState from,
    required SitePermissionState to,
  }) => from != to &&
          (to == SitePermissionState.blocked || to == SitePermissionState.ask)
      ? forget(permission)
      : this;

  Map<String, Map<String, bool>> toJson() => {
    for (final MapEntry(:key, :value) in _byPermission.entries)
      key.name: {...value},
  };

  /// A wrong-typed entry reads as absent, so a hand-edited file loses only
  /// that entry.
  static OriginChoices fromJson(Object? json) {
    if (json is! Map) return none;
    final byName = {for (final p in SitePermission.values) p.name: p};
    return OriginChoices._({
      for (final MapEntry(:key, :value) in json.entries)
        if ((byName[key], value) case (final SitePermission p, final Map m))
          if ({
            for (final MapEntry(:key, :value) in m.entries)
              if ((key, value) case (final String origin, final bool allowed))
                origin: allowed,
          } case final origins when origins.isNotEmpty)
            p: origins,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is OriginChoices && _sameChoices(other._byPermission);

  bool _sameChoices(Map<SitePermission, Map<String, bool>> other) =>
      other.length == _byPermission.length &&
      _byPermission.entries.every((e) {
        final theirs = other[e.key];
        return theirs != null &&
            theirs.length == e.value.length &&
            e.value.entries.every((o) => theirs[o.key] == o.value);
      });

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final MapEntry(:key, :value) in _byPermission.entries)
      Object.hash(
        key,
        Object.hashAllUnordered([
          for (final o in value.entries) Object.hash(o.key, o.value),
        ]),
      ),
  ]);
}
