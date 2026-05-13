import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the encoded trusted-cert pin list.
/// Round-tripped through settings export/import via [kExportedAppPrefs].
const String kTrustedHostsKey = 'trustedHosts';

/// One pinned (host, port, sha256) triple. Pinning the cert fingerprint
/// (not just the host) means the user gets re-prompted if the cert is
/// rotated or substituted, matching desktop-browser exception semantics.
@immutable
class TrustedHostEntry {
  final String host;
  final int port;
  final String sha256Hex;

  const TrustedHostEntry({
    required this.host,
    required this.port,
    required this.sha256Hex,
  });

  static const String _sep = '|';

  String encode() => '$host$_sep$port$_sep$sha256Hex';

  static TrustedHostEntry? decode(String raw) {
    final parts = raw.split(_sep);
    if (parts.length != 3) return null;
    final port = int.tryParse(parts[1]);
    if (port == null || parts[0].isEmpty || parts[2].isEmpty) return null;
    return TrustedHostEntry(host: parts[0], port: port, sha256Hex: parts[2]);
  }

  @override
  bool operator ==(Object other) =>
      other is TrustedHostEntry &&
      other.host == host &&
      other.port == port &&
      other.sha256Hex == sha256Hex;

  @override
  int get hashCode => Object.hash(host, port, sha256Hex);
}

/// Trust list for self-signed / otherwise-untrusted TLS certificates.
///
/// The webview's `onReceivedServerTrustAuthRequest` and the Dart-side
/// `HttpClient.badCertificateCallback` both consult this list before
/// proceeding. New entries are added only after the user explicitly
/// approves the cert in a prompt — there is no API to silently trust a
/// host. Removing an entry forces the prompt to re-appear next visit.
class TrustedHostsService {
  TrustedHostsService._();
  static final TrustedHostsService instance = TrustedHostsService._();

  final Map<String, String> _byHostPort = <String, String>{};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(kTrustedHostsKey) ?? const <String>[];
    _byHostPort.clear();
    for (final s in raw) {
      final entry = TrustedHostEntry.decode(s);
      if (entry != null) _byHostPort[_key(entry.host, entry.port)] = entry.sha256Hex;
    }
    _initialized = true;
  }

  /// Whether (host, port) is pinned and the supplied cert fingerprint
  /// matches. A null [fingerprint] is treated as "no proof" and rejected
  /// — every caller has access to the cert via the platform callback,
  /// so a null here is a bug, not a fallback.
  bool isTrusted({
    required String host,
    required int port,
    required String? fingerprint,
  }) {
    if (fingerprint == null) return false;
    final pinned = _byHostPort[_key(host, port)];
    return pinned != null && pinned.toLowerCase() == fingerprint.toLowerCase();
  }

  Future<void> trust({
    required String host,
    required int port,
    required String fingerprint,
  }) async {
    _byHostPort[_key(host, port)] = fingerprint.toLowerCase();
    await _persist();
  }

  Future<void> untrust({required String host, required int port}) async {
    if (_byHostPort.remove(_key(host, port)) != null) {
      await _persist();
    }
  }

  /// Drop every pinned entry. Used by the one-shot migration in
  /// `main.dart`, the future settings UI, and tests.
  Future<void> clear() async {
    _byHostPort.clear();
    await _persist();
  }

  List<TrustedHostEntry> all() {
    final out = <TrustedHostEntry>[];
    for (final entry in _byHostPort.entries) {
      final i = entry.key.indexOf(':');
      if (i <= 0) continue;
      final host = entry.key.substring(0, i);
      final port = int.tryParse(entry.key.substring(i + 1));
      if (port == null) continue;
      out.add(TrustedHostEntry(host: host, port: port, sha256Hex: entry.value));
    }
    return out;
  }

  /// SHA-256 fingerprint (lowercase hex) of an InAppWebView SSL cert, or
  /// null if the platform did not surface the DER bytes (some Linux/WPE
  /// builds, very old Android). When null, the prompt path still works
  /// but the trust decision can't be persisted with a fingerprint.
  static String? fingerprintFromInappCertificate(inapp.SslCertificate? cert) {
    final der = cert?.x509Certificate?.encoded;
    if (der == null || der.isEmpty) return null;
    return sha256.convert(der).toString();
  }

  /// SHA-256 fingerprint of a dart:io X509Certificate (used by
  /// `HttpClient.badCertificateCallback`).
  static String fingerprintFromX509(X509Certificate cert) {
    return sha256.convert(cert.der).toString();
  }

  String _key(String host, int port) => '${host.toLowerCase()}:$port';

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = all().map((e) => e.encode()).toList();
    await prefs.setStringList(kTrustedHostsKey, entries);
  }

  /// Re-hydrate from the SharedPreferences value carried by a settings
  /// import. Unlike [initialize], this overwrites the in-memory state.
  @visibleForTesting
  Future<void> reloadFromPrefs() async {
    _initialized = false;
    await initialize();
  }
}
