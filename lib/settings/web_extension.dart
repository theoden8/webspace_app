import 'dart:math';

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

/// An extension in the library: who it is, and what its manifest asked for
/// when it was imported, which is what a site's grants are cut from.
final class WebExtensionEntry {
  const WebExtensionEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.permissions,
    required this.hosts,
  });

  final WebExtensionId id;
  final String name;
  final String version;

  /// The API permissions it asked for.
  final Set<String> permissions;

  /// The match patterns it asked to reach.
  final Set<String> hosts;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'permissions': permissions.toList()..sort(),
    'hosts': hosts.toList()..sort(),
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
    );
  }
}

/// A library entry and the folder its files are unpacked in, which the
/// webview loads it from.
typedef InstalledExtension = ({WebExtensionEntry entry, String folder});
