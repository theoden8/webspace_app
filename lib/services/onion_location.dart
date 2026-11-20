/// A site's own onion address, as its HTTPS answer announces it
/// (`Onion-Location`, ONION-001), and the rewrite of its clearnet origin onto
/// it (ONION-004). Pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha3.dart';
import 'package:webspace/services/url_host.dart';

/// A v3 onion service (rend-spec-v3, "Encoding onion addresses"): its
/// 56-character label, which carries the service's ed25519 key, a checksum
/// over it and the version. Only [ofHost] makes one, so a value has been
/// checked (ONION-002).
extension type const OnionAddress._(String label) implements String {
  /// The service [host] names, a subdomain's included (`www.<label>.onion`
  /// is the same key), or null when it names no well formed v3 service.
  static OnionAddress? ofHost(Host host) {
    final labels = host.split('.');
    if (labels.length < 2 || labels.last != 'onion') return null;
    final label = labels[labels.length - 2];
    final bytes = _base32(label);
    if (bytes == null || bytes.length != 35) return null;
    final key = bytes.sublist(0, 32);
    final version = bytes[34];
    if (version != 3) return null;
    final sum = _checksum(key, version: version);
    if (bytes[32] != sum[0] || bytes[33] != sum[1]) return null;
    return OnionAddress._(label);
  }

  static List<int> _checksum(Uint8List key, {required int version}) {
    final input = BytesBuilder()
      ..add(utf8.encode('.onion checksum'))
      ..add(key)
      ..addByte(version);
    return SHA3Digest(256).process(input.toBytes()).sublist(0, 2);
  }

  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

  static Uint8List? _base32(String text) {
    if (text.length != 56) return null;
    final out = BytesBuilder();
    var buffer = 0;
    var bits = 0;
    for (final c in text.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) return null;
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((buffer >> bits) & 0xff);
      }
    }
    return out.toBytes();
  }
}

/// The onion origin a site announced for its clearnet origin: every top-frame
/// load of [from] goes to [to] with its path kept, while the site is on Tor
/// and the user accepted it (ONION-004). Both are origins in `originOf` form.
final class OnionEndpoint {
  const OnionEndpoint._({
    required this.from,
    required this.to,
    required this.service,
  });

  /// The endpoint [to] names for the clearnet origin [from], or null when
  /// [from] is not an https origin or [to] is not an http(s) origin of a v3
  /// onion service on its scheme's own port (ONION-001, ONION-002).
  static OnionEndpoint? of({required String from, required String to}) {
    final clear = _origin(from);
    final onion = _origin(to);
    if (clear == null || onion == null) return null;
    if (clear.uri.scheme != 'https' || Host(clear.uri.host).isOnion) {
      return null;
    }
    final service = OnionAddress.ofHost(Host(onion.uri.host));
    if (service == null) return null;
    return OnionEndpoint._(from: clear.text, to: onion.text, service: service);
  }

  final String from;
  final String to;
  final OnionAddress service;

  /// [url] on the onion origin when it is on [from] exactly (scheme, host and
  /// port), its path, query and fragment kept; else null.
  String? rewrite(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final at = _origin(url);
    if (at == null || at.text != from) return null;
    final onion = Uri.parse(to);
    return uri.replace(scheme: onion.scheme, host: onion.host, port: null)
        .toString();
  }

  /// [url] back on the clearnet origin when it is on the onion origin,
  /// path, query and fragment kept; else null.
  String? back(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final at = _origin(url);
    if (at == null || at.text != to) return null;
    final clear = Uri.parse(from);
    return uri.replace(scheme: clear.scheme, host: clear.host, port: null)
        .toString();
  }

  /// Whether [url] is on the onion origin.
  bool isOnion(String url) => _origin(url)?.text == to;

  @override
  bool operator ==(Object other) =>
      other is OnionEndpoint && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'OnionEndpoint($from -> $to)';

  /// [url]'s origin when it is http(s) with a host and the scheme's own port.
  static ({Uri uri, String text})? _origin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)) {
      return null;
    }
    final host = Host(uri.host);
    return (uri: uri, text: '${uri.scheme}://$host');
  }
}

/// What the site's answer for its home address announces: the
/// `Onion-Location` header, else the `<meta http-equiv="onion-location">` of
/// the document's head (ONION-001). [answeredBy] is the URL that answered
/// after redirects; only an https answer counts. Null when it announces no
/// well formed onion origin.
OnionEndpoint? announcedEndpoint({
  required Uri answeredBy,
  required String? header,
  required String document,
}) {
  if (answeredBy.scheme != 'https') return null;
  final value = header?.trim().isNotEmpty == true
      ? header!.trim()
      : _metaOnionLocation(document);
  if (value == null) return null;
  return OnionEndpoint.of(from: answeredBy.toString(), to: value);
}

final _metaTag = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
final _attribute = RegExp(
    r'''([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''');

String? _metaOnionLocation(String document) {
  final lower = document.toLowerCase();
  var end = lower.indexOf('</head');
  final body = lower.indexOf('<body');
  if (end < 0 || (body >= 0 && body < end)) end = body;
  final head = end < 0 ? document : document.substring(0, end);
  for (final tag in _metaTag.allMatches(head)) {
    final attributes = <String, String>{
      for (final a in _attribute.allMatches(tag.group(0)!))
        a.group(1)!.toLowerCase(): a.group(2) ?? a.group(3) ?? a.group(4)!,
    };
    if (attributes['http-equiv']?.trim().toLowerCase() == 'onion-location') {
      final content = attributes['content']?.trim();
      if (content != null && content.isNotEmpty) return content;
    }
  }
  return null;
}

/// What the user answered about an announced onion address (ONION-003).
enum OnionAnswer { accepted, declined }

/// What a load the move sent to the onion origin does when it fails, is
/// rejected by TLS or says nothing (ONION-006): stay on the failure, or load
/// the clearnet URL it moved, through an exit. The user chooses; staying is
/// the default.
enum OnionFallback { none, clearnet }

/// The onion origin a site's webviews move onto while it is on Tor, and what
/// a failure there does.
typedef OnionRoute = ({OnionEndpoint endpoint, OnionFallback fallback});

/// A site's onion address as last learned from its own answer (ONION-001),
/// when that check succeeded and what the user answered, null while they
/// have not been asked. Saved with the site, never in a backup or a QR share
/// (ONION-008).
final class SiteOnion {
  const SiteOnion({
    required this.endpoint,
    required this.checked,
    required this.answer,
    required this.fallback,
  });

  final OnionEndpoint endpoint;
  final DateTime checked;
  final OnionAnswer? answer;
  final OnionFallback fallback;

  /// The route a webview of the site moves onto: only an accepted endpoint,
  /// and only while the site's route is Tor (ONION-004, ONION-007).
  OnionRoute? routeOn({required bool tor}) =>
      tor && answer == OnionAnswer.accepted
          ? (endpoint: endpoint, fallback: fallback)
          : null;

  /// The URL a webview of the site starts at, given the endpoint [inUse]: a
  /// saved onion URL goes back to the clearnet origin when the endpoint is
  /// not in use (ONION-007); the move onto it is the first load's
  /// (`HttpsUpgradeEngine.onFirstLoad`), so a failure there is the route's.
  String startUrl(String url, {required OnionEndpoint? inUse}) =>
      inUse == null ? endpoint.back(url) ?? url : url;

  Map<String, Object> toJson() => {
    'from': endpoint.from,
    'to': endpoint.to,
    'checked': checked.toUtc().toIso8601String(),
    if (answer != null) 'answer': answer!.name,
    'fallback': fallback.name,
  };

  /// The saved value, or null for one absent or of the wrong shape, which
  /// reads as nothing learned (ONION-008).
  static SiteOnion? fromJson(Object? json) {
    if (json case {
      'from': final String from,
      'to': final String to,
      'checked': final String checked,
    }) {
      final endpoint = OnionEndpoint.of(from: from, to: to);
      final at = DateTime.tryParse(checked);
      if (endpoint == null || at == null) return null;
      final answer = switch (json['answer']) {
        'accepted' => OnionAnswer.accepted,
        'declined' => OnionAnswer.declined,
        _ => null,
      };
      final fallback = switch (json['fallback']) {
        'clearnet' => OnionFallback.clearnet,
        _ => OnionFallback.none,
      };
      return SiteOnion(
          endpoint: endpoint, checked: at, answer: answer, fallback: fallback);
    }
    return null;
  }
}
