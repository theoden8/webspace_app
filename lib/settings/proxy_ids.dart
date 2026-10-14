import 'dart:math';

/// The proxy library's three kinds of entry each have an id of their own,
/// so a gateway's id cannot name credentials or a saved proxy. Each is
/// random and never shown, made by `mint` for a new entry and `parse` for
/// one read from storage or a backup.
String _mint() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
}

String? _nonEmpty(Object? raw) => raw is String && raw.isNotEmpty ? raw : null;

/// A saved gateway's identity.
extension type const GatewayId._(String raw) implements String {
  /// An id the library made or handed out before.
  factory GatewayId(String raw) {
    assert(raw.isNotEmpty, 'a gateway id is not empty');
    return GatewayId._(raw);
  }

  factory GatewayId.mint() => GatewayId._(_mint());

  static GatewayId? parse(Object? raw) =>
      _nonEmpty(raw) == null ? null : GatewayId._(raw as String);
}

/// Saved credentials' identity.
extension type const CredentialsId._(String raw) implements String {
  /// An id the library made or handed out before.
  factory CredentialsId(String raw) {
    assert(raw.isNotEmpty, 'a credentials id is not empty');
    return CredentialsId._(raw);
  }

  factory CredentialsId.mint() => CredentialsId._(_mint());

  static CredentialsId? parse(Object? raw) =>
      _nonEmpty(raw) == null ? null : CredentialsId._(raw as String);
}

/// A saved proxy's identity.
extension type const SavedProxyId._(String raw) implements String {
  /// An id the library made or handed out before.
  factory SavedProxyId(String raw) {
    assert(raw.isNotEmpty, 'a saved proxy id is not empty');
    return SavedProxyId._(raw);
  }

  factory SavedProxyId.mint() => SavedProxyId._(_mint());

  static SavedProxyId? parse(Object? raw) =>
      _nonEmpty(raw) == null ? null : SavedProxyId._(raw as String);
}
