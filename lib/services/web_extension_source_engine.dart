/// What an extension's source says about its latest release, and what that
/// means for the extension in the library: the packages to offer when it is
/// added from a link (WEBEXT-017), and whether an update is out, when to
/// look, and what an update asks for that the installed version did not
/// (WEBEXT-018).
///
/// The replies are untrusted JSON, read by patterns: a wrong-typed field
/// reads as absent.
library;

import 'dart:math' show max;

import 'package:webspace/services/web_extension_package_engine.dart'
    show ExtensionManifest;
import 'package:webspace/settings/web_extension.dart';
import 'package:webspace/settings/web_extension_source.dart';

/// The request that reads [source]'s latest release, downloading nothing.
Uri releaseQuery(ExtensionSource source) => switch (source) {
  AmoSource(:final slug) => Uri.https(
    'addons.mozilla.org',
    '/api/v5/addons/addon/$slug/',
  ),
  GitHubSource(:final owner, :final repo) => Uri.https(
    'api.github.com',
    '/repos/$owner/$repo/releases/latest',
  ),
};

/// A package's file name suffix, in the order packages are offered: a
/// Chrome package first, which WebKit is written for. The bytes, never the
/// name, decide how a downloaded package is read.
enum AssetSuffix {
  crx('.crx'),
  zip('.zip'),
  xpi('.xpi');

  const AssetSuffix(this.text);

  final String text;

  /// The suffix [name] ends in, ignoring case; null for any other file.
  static AssetSuffix? of(String name) {
    final lower = name.toLowerCase();
    for (final suffix in values) {
      if (lower.endsWith(suffix.text)) return suffix;
    }
    return null;
  }
}

/// A package a release offers, not yet downloaded.
final class PackageCandidate {
  const PackageCandidate._({
    required this.name,
    required this.url,
    required this.size,
    required this.suffix,
    required this.permissions,
  });

  final String name;

  /// Where it downloads from, always over https.
  final Uri url;

  /// Its size in bytes, where the source says.
  final int? size;
  final AssetSuffix suffix;

  /// The permissions and hosts the source lists for it before it is
  /// downloaded; empty where the source lists none, as GitHub does.
  final Set<String> permissions;
}

/// What a source's reply says of its latest release.
sealed class ReleaseRead {
  const ReleaseRead();
}

final class ReleaseFound extends ReleaseRead {
  ReleaseFound({
    required this.version,
    required List<PackageCandidate> candidates,
  }) : assert(candidates.isNotEmpty, 'a release found offers a package'),
       candidates = List.unmodifiable(candidates);

  final String version;

  /// In the order they are offered: the kind of file picked before first,
  /// then by [AssetSuffix].
  final List<PackageCandidate> candidates;
}

final class ReleaseRefused extends ReleaseRead {
  const ReleaseRefused(this.why);
  final ReleaseProblem why;
}

enum ReleaseProblem {
  /// The reply is not a JSON object.
  notJson,

  /// The reply names no version that starts with a number.
  noVersion,

  /// The release has no `.crx`, `.zip` or `.xpi` downloadable over https,
  /// or the listing is not an extension.
  noPackage,
}

/// [json], the decoded reply to [source]'s [releaseQuery], as a release.
/// The caller passes null for a body that did not decode.
ReleaseRead readRelease(ExtensionSource source, {required Object? json}) {
  if (json is! Map<String, Object?>) {
    return const ReleaseRefused(ReleaseProblem.notJson);
  }
  return switch (source) {
    AmoSource() => _amoRelease(json),
    GitHubSource(:final asset) => _gitHubRelease(json, asset: asset),
  };
}

ReleaseRead _amoRelease(Map<String, Object?> addon) {
  final current = switch (addon['current_version']) {
    final Map<String, Object?> v => v,
    _ => const <String, Object?>{},
  };
  final version = _versionOf(current['version']);
  if (version == null) return const ReleaseRefused(ReleaseProblem.noVersion);
  if (addon['type'] case final String type when type != 'extension') {
    return const ReleaseRefused(ReleaseProblem.noPackage);
  }
  final file = switch (current['file']) {
    final Map<String, Object?> f => f,
    _ => const <String, Object?>{},
  };
  final url = switch (file['url']) {
    final String s => s,
    _ => null,
  };
  final candidate = _candidate(
    name: url == null ? null : Uri.tryParse(url)?.pathSegments.lastOrNull,
    url: url,
    size: file['size'],
    permissions: {
      ..._strings(file['permissions']),
      ..._strings(file['host_permissions']),
    },
  );
  return _found(version: version, candidates: [?candidate], asset: null);
}

ReleaseRead _gitHubRelease(
  Map<String, Object?> release, {
  required String? asset,
}) {
  final version = _versionOf(release['tag_name']);
  if (version == null) return const ReleaseRefused(ReleaseProblem.noVersion);
  final assets = switch (release['assets']) {
    final List<Object?> list => list,
    _ => const <Object?>[],
  };
  return _found(
    version: version,
    candidates: [
      for (final entry in assets)
        if (entry case final Map<String, Object?> listed)
          ?_candidate(
            name: listed['name'],
            url: listed['browser_download_url'],
            size: listed['size'],
            permissions: const {},
          ),
    ],
    asset: asset,
  );
}

/// [raw] as a release version, a leading `v` dropped; null unless it then
/// starts with a number.
String? _versionOf(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  final version = trimmed.startsWith(RegExp('[vV]'))
      ? trimmed.substring(1)
      : trimmed;
  return version.startsWith(RegExp('[0-9]')) ? version : null;
}

PackageCandidate? _candidate({
  required Object? name,
  required Object? url,
  required Object? size,
  required Set<String> permissions,
}) {
  if (name is! String) return null;
  final suffix = AssetSuffix.of(name);
  final uri = url is String ? Uri.tryParse(url) : null;
  if (suffix == null ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty) {
    return null;
  }
  return PackageCandidate._(
    name: name,
    url: uri,
    size: switch (size) {
      final int bytes when bytes >= 0 => bytes,
      _ => null,
    },
    suffix: suffix,
    permissions: Set.unmodifiable(permissions),
  );
}

/// The release, its [candidates] offered in order: those named like
/// [asset] first, then by suffix, each group in the order the source
/// listed them.
ReleaseRead _found({
  required String version,
  required List<PackageCandidate> candidates,
  required String? asset,
}) {
  if (candidates.isEmpty) return const ReleaseRefused(ReleaseProblem.noPackage);
  final bySuffix = [
    for (final suffix in AssetSuffix.values)
      ...candidates.where((c) => c.suffix == suffix),
  ];
  final picked = asset == null ? null : _assetMatcher(asset);
  return ReleaseFound(
    version: version,
    candidates: picked == null
        ? bySuffix
        : [
            ...bySuffix.where((c) => picked.hasMatch(c.name)),
            ...bySuffix.where((c) => !picked.hasMatch(c.name)),
          ],
  );
}

RegExp _assetMatcher(String pattern) =>
    RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$');

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

/// [assetName] with [version], with or without a leading `v`, as `*`, so
/// the next release's file of the same kind matches it; the name itself
/// when it does not carry the version.
String assetPattern(String assetName, {required String version}) {
  final bare = version.startsWith(RegExp('[vV]'))
      ? version.substring(1)
      : version;
  if (bare.isEmpty) return assetName;
  final within = RegExp('(?<![0-9.])[vV]?${RegExp.escape(bare)}(?!\\.?[0-9])');
  return assetName.replaceAll(within, '*');
}

/// Below zero when [version] is older than [to], zero when they are the
/// same, above zero when it is newer; as Firefox compares them, so Chrome's
/// dotted numbers compare too. Each dot-separated part is a number, a
/// string, a number and the rest, compared in that order; a missing number
/// is 0 and a missing string is newer than any (`1.0b2` before `1.0`); a
/// missing part is `0` (`2.0` is `2.0.0`).
int compareExtensionVersions(String version, {required String to}) {
  final left = version.split('.');
  final right = to.split('.');
  for (var i = 0; i < max(left.length, right.length); i++) {
    final a = _VersionPart.of(i < left.length ? left[i] : '');
    final b = _VersionPart.of(i < right.length ? right[i] : '');
    final order = a.compareTo(b);
    if (order != 0) return order;
  }
  return 0;
}

/// One dot-separated part of a version: `0b2` is the number 0, the tag
/// `b`, the tag's number 2 and no rest. The numbers are digits, compared
/// as numbers of any length.
final class _VersionPart implements Comparable<_VersionPart> {
  const _VersionPart({
    required this.number,
    required this.tag,
    required this.tagNumber,
    required this.rest,
  });

  factory _VersionPart.of(String part) {
    final m = _shape.firstMatch(part)!;
    return _VersionPart(
      number: m[1]!,
      tag: m[2]!,
      tagNumber: m[3]!,
      rest: m[4]!,
    );
  }

  static final _shape = RegExp(r'^(\d*)(\D*)(\d*)(.*)$', dotAll: true);

  final String number;
  final String tag;
  final String tagNumber;
  final String rest;

  @override
  int compareTo(_VersionPart other) {
    for (final order in [
      _compareNumbers(number, than: other.number),
      _compareStrings(tag, than: other.tag),
      _compareNumbers(tagNumber, than: other.tagNumber),
      _compareStrings(rest, than: other.rest),
    ]) {
      if (order != 0) return order;
    }
    return 0;
  }

  static int _compareNumbers(String digits, {required String than}) {
    final a = digits.replaceFirst(RegExp('^0+'), '');
    final b = than.replaceFirst(RegExp('^0+'), '');
    return a.length != b.length ? a.length.compareTo(b.length) : a.compareTo(b);
  }

  static int _compareStrings(String text, {required String than}) =>
      text == than
      ? 0
      : text.isEmpty
      ? 1
      : than.isEmpty
      ? -1
      : text.compareTo(than);
}

/// Whether [installedVersion] is behind what [release] says is out.
sealed class UpdateCheck {
  const UpdateCheck();
}

final class UpToDate extends UpdateCheck {
  const UpToDate();
}

final class UpdateAvailable extends UpdateCheck {
  const UpdateAvailable(this.version);
  final String version;
}

final class CheckFailed extends UpdateCheck {
  const CheckFailed(this.why);
  final ReleaseProblem why;
}

UpdateCheck checkUpdate({
  required String installedVersion,
  required ReleaseRead release,
}) => switch (release) {
  ReleaseRefused(:final why) => CheckFailed(why),
  ReleaseFound(:final version) =>
    compareExtensionVersions(version, to: installedVersion) > 0
        ? UpdateAvailable(version)
        : const UpToDate(),
};

/// What an update's manifest asks for beyond what the installed version
/// asked for, which the user accepts before it installs.
sealed class UpdateAsks {
  const UpdateAsks();
}

final class AsksNothingNew extends UpdateAsks {
  const AsksNothingNew();
}

final class AsksMore extends UpdateAsks {
  AsksMore({required this.permissions, required this.hosts})
    : assert(
        permissions.isNotEmpty || hosts.isNotEmpty,
        'an update asking for more names what',
      );

  final Set<String> permissions;
  final Set<String> hosts;
}

UpdateAsks updateAsks({
  required WebExtensionEntry installed,
  required ExtensionManifest update,
}) {
  final permissions = update.permissions.difference(installed.permissions);
  final hosts = update.hosts.difference(installed.hosts);
  return permissions.isEmpty && hosts.isEmpty
      ? const AsksNothingNew()
      : AsksMore(permissions: permissions, hosts: hosts);
}

/// How long a source's latest release is taken as read.
const Duration updateCheckInterval = Duration(days: 1);

/// Whether a source last read at [lastChecked] is read again at [now]: at
/// most once per [updateCheckInterval], and again when the clock went back
/// past the last read.
bool checkDue({required DateTime? lastChecked, required DateTime now}) =>
    lastChecked == null ||
    lastChecked.isAfter(now) ||
    now.difference(lastChecked) >= updateCheckInterval;
