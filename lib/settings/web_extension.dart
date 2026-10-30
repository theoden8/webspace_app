import 'dart:math';

import 'package:webspace/settings/web_extension_source.dart';

/// An id names the extension's folder and is the host of its
/// `webkit-extension://` origin, so it is a lower-case DNS label.
final RegExp _kWebExtensionIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');

/// An imported web extension's identity, minted on import. A site's
/// switched-on extensions are a set of these. The manifest's own `key` or
/// Gecko id is never trusted as identity.
extension type const WebExtensionId._(String raw) implements String {
  /// An id the app made or handed out before.
  factory WebExtensionId(String raw) {
    assert(
      _kWebExtensionIdPattern.hasMatch(raw),
      'a web extension id is a DNS label: $raw',
    );
    return WebExtensionId._(raw);
  }

  factory WebExtensionId.mint() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = Random.secure().nextInt(1 << 32);
    return WebExtensionId._(
      'we-${now.toRadixString(36)}-${random.toRadixString(36)}',
    );
  }

  /// [raw] when it is a DNS label; null otherwise.
  static WebExtensionId? parse(Object? raw) =>
      raw is String && _kWebExtensionIdPattern.hasMatch(raw)
      ? WebExtensionId._(raw)
      : null;
}

/// An extension in the library: who it is, what its manifest asked for
/// when it was imported, which is what a site's grants are cut from,
/// whether a site that sets no choice of its own runs it (WEBEXT-004), and
/// for one added from a link, its source and what its last check found
/// (WEBEXT-017, WEBEXT-018).
final class WebExtensionEntry {
  const WebExtensionEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.permissions,
    required this.hosts,
    required this.everySite,
    this.source,
    this.checkedAt,
    this.latest,
  });

  final WebExtensionId id;
  final String name;
  final String version;

  /// The API permissions it asked for.
  final Set<String> permissions;

  /// The match patterns it asked to reach.
  final Set<String> hosts;

  /// What a site that follows the extension's default runs: off until the
  /// user switches it on for every site.
  final bool everySite;

  /// Where it was added from, which its updates are read from; null for an
  /// extension imported from a file.
  final ExtensionSource? source;

  /// When its source was last read.
  final DateTime? checkedAt;

  /// The newer version that read found, not yet installed.
  final String? latest;

  WebExtensionEntry withEverySite({required bool on}) => WebExtensionEntry(
    id: id,
    name: name,
    version: version,
    permissions: permissions,
    hosts: hosts,
    everySite: on,
    source: source,
    checkedAt: checkedAt,
    latest: latest,
  );

  /// What a read of its source at [at] found: [latest] when newer than the
  /// installed version.
  WebExtensionEntry withCheck({required DateTime at, required String? latest}) =>
      WebExtensionEntry(
        id: id,
        name: name,
        version: version,
        permissions: permissions,
        hosts: hosts,
        everySite: everySite,
        source: source,
        checkedAt: at,
        latest: latest,
      );

  /// The entry once an update's manifest is installed over it, keeping its
  /// id, its default for every site and its source.
  WebExtensionEntry updatedTo({
    required String name,
    required String version,
    required Set<String> permissions,
    required Set<String> hosts,
  }) => WebExtensionEntry(
    id: id,
    name: name,
    version: version,
    permissions: permissions,
    hosts: hosts,
    everySite: everySite,
    source: source,
    checkedAt: checkedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'permissions': permissions.toList()..sort(),
    'hosts': hosts.toList()..sort(),
    if (everySite) 'everySite': true,
    if (source case final from?) 'source': from.toJson(),
    if (checkedAt case final at?) 'checkedAt': at.toUtc().toIso8601String(),
    if (latest case final version?) 'latest': version,
  };

  /// Null when [json] does not name a valid id; a wrong-typed field reads
  /// as absent.
  static WebExtensionEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = WebExtensionId.parse(json['id']);
    if (id == null) return null;
    Set<String> strings(Object? value) =>
        value is List ? value.whereType<String>().toSet() : const {};
    return WebExtensionEntry(
      id: id,
      name: switch (json['name']) {
        final String s => s,
        _ => id,
      },
      version: switch (json['version']) {
        final String s => s,
        _ => '',
      },
      permissions: strings(json['permissions']),
      hosts: strings(json['hosts']),
      everySite: json['everySite'] == true,
      source: ExtensionSource.fromJson(json['source']),
      checkedAt: switch (json['checkedAt']) {
        final String at => DateTime.tryParse(at),
        _ => null,
      },
      latest: switch (json['latest']) {
        final String version when version.isNotEmpty => version,
        _ => null,
      },
    );
  }
}

/// A library entry and the folder its files are unpacked in, which the
/// webview loads it from.
typedef InstalledExtension = ({WebExtensionEntry entry, String folder});
