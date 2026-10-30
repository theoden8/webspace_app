import 'dart:convert';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/bounded_inflate.dart';
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';

/// Encode/decode the QR-shareable subset of a [WebViewModel] JSON dict.
///
/// The QR payload intentionally carries only non-secret per-site
/// configuration. Excluded by design: `cookies` (incl. secure cookies),
/// `userScripts`, `enabledGlobalScriptIds`, `blockedCookies`, `siteId`
/// (receiver mints fresh), `currentUrl`/`pageTitle` (runtime state).
/// Proxy passwords never leave the device — `UserProxySettings.toJson`
/// strips them per `proxy-password-secure-storage` (PWD-005), and [decode]
/// strips any a hand-crafted payload smuggled in.
///
/// Wire format: `webspace://qr/site/v1/<base64url>` where the payload is
/// gzip-compressed UTF-8 JSON. base64url padding is stripped on encode and
/// reapplied on decode.
///
/// Whether a field rides a QR is its [SiteField]'s `qr`, which every field
/// must declare, so an unreviewed field cannot reach a shared code.
class SiteSettingsQrCodec {
  SiteSettingsQrCodec._();

  static const int currentVersion = 1;
  static const String _scheme = 'webspace';
  static const String _path = 'qr/site';

  /// Per-site keys the QR is allowed to carry.
  static final Set<String> includedKeys = {
    for (final field in SiteField.values)
      if (field.qr == QrShare.carried) ...field.keys,
  };

  /// Strip a full `WebViewModel.toJson()` to the QR-shareable subset.
  ///
  /// A site that uses the proxy library (a saved proxy, gateway or
  /// credentials) carries the resolved route instead of the references: ids
  /// are local to this device, so the receiver could only fail closed on one.
  /// A reference that no longer resolves carries no proxy at all.
  static Map<String, dynamic> shareableSubset(Map<String, dynamic> fullJson) {
    final out = <String, dynamic>{};
    for (final k in includedKeys) {
      if (fullJson.containsKey(k)) out[k] = fullJson[k];
    }
    if (out['proxySettings'] case final Map stored) {
      // An interface name means nothing on another device (NETIF-012).
      final proxy = out['proxySettings'] = <String, dynamic>{
        for (final e in stored.entries)
          if (e.key case final String key when key != 'networkInterface')
            key: e.value,
      };
      final settings = UserProxySettings.fromJson(proxy);
      if (settings.type == ProxyType.SAVED ||
          settings.type == ProxyType.GATEWAY ||
          settings.credentialsId != null) {
        final resolved = resolveLibraryProxy(settings);
        if (resolved.type == ProxyType.SAVED) {
          out.remove('proxySettings');
        } else {
          out['proxySettings'] = resolved.toJson();
        }
      }
    }
    return out;
  }

  /// Pad a stripped subset with empty placeholders for fields
  /// `WebViewModel.fromJson` reads as required (currently `cookies`).
  static Map<String, dynamic> hydrateForFromJson(
    Map<String, dynamic> stripped,
  ) {
    return {
      ...stripped,
      'cookies': const <dynamic>[],
    };
  }

  /// Encode a shareable subset to a `webspace://qr/site/vN/<payload>` URI.
  static String encode(Map<String, dynamic> shareable) {
    final jsonStr = jsonEncode(shareable);
    final compressed = hostGzipEncoder.convert(utf8.encode(jsonStr));
    final payload = base64Url.encode(compressed).replaceAll('=', '');
    return '$_scheme://$_path/v$currentVersion/$payload';
  }

  // A per-site settings payload is a few hundred bytes; these ceilings leave
  // generous headroom while bounding a decompression bomb.
  static const int _kMaxCompressedBytes = 64 * 1024;
  static const int _kMaxDecodedBytes = 256 * 1024;

  /// Gzip-inflate [compressed], or null on output past [maxOut] or a
  /// malformed stream.
  static List<int>? _gunzipBounded(List<int> compressed,
      {required int maxOut}) {
    try {
      return inflateBounded(hostGzipDecoder,
          compressed: compressed, limit: maxOut);
    } on FormatException {
      return null;
    }
  }

  /// Decode a `webspace://qr/site/vN/<payload>` URI back to a shareable
  /// subset. Returns null if the input is malformed, the version is newer
  /// than [currentVersion], the payload fails gunzip, or `initUrl` is
  /// missing. Any keys outside [includedKeys] in a successfully decoded
  /// payload are dropped — a hostile sender cannot smuggle, e.g.,
  /// `cookies` past the receiver's strip filter.
  static Map<String, dynamic>? decode(String input) {
    final parsed = _parse(input.trim());
    if (parsed == null) return null;
    try {
      final padding = (4 - parsed.payload.length % 4) % 4;
      final padded = parsed.payload + ('=' * padding);
      final compressed = base64Url.decode(padded);
      // The paste path accepts arbitrary-length clipboard text (the physical
      // QR capacity bound does not apply), so cap both the compressed input
      // and the decompressed output to defeat a gzip decompression bomb.
      if (compressed.length > _kMaxCompressedBytes) return null;
      final bytes = _gunzipBounded(compressed, maxOut: _kMaxDecodedBytes);
      if (bytes == null) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final out = <String, dynamic>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        if (key is String && includedKeys.contains(key)) {
          out[key] = entry.value;
        }
      }
      // `includedKeys` whitelists top-level keys only, so the nested
      // `proxySettings` object arrives unexamined. `UserProxySettings.toJson`
      // never emits a password, but a hostile sender is not bound by our
      // encoder — and `fromJson` would happily read one straight into the
      // receiver's live proxy credentials.
      final proxy = out['proxySettings'];
      if (proxy is Map) {
        final stripped = <String, dynamic>{
          for (final e in proxy.entries)
            if (e.key is String &&
                !const {
                  'password',
                  'savedProxyId',
                  'gatewayId',
                  'credentialsId',
                  'networkInterface',
                }.contains(e.key))
              e.key as String: e.value,
        };
        // `UserProxySettings.fromJson` coerces a numeric-string `type`, so
        // a value the review dialog could not classify would still apply.
        // Hold the payload to exactly what our own encoder emits.
        // Library routes are never emitted: [shareableSubset] resolves them.
        final type = stripped['type'];
        if (type != null &&
            (type is! int ||
                type < 0 ||
                type >= ProxyType.values.length ||
                type == ProxyType.SAVED.index ||
                type == ProxyType.GATEWAY.index)) {
          return null;
        }
        for (final key in const ['address', 'username', 'torExitCountry']) {
          final value = stripped[key];
          if (value != null && value is! String) return null;
        }
        out['proxySettings'] = stripped;
      }
      if (out['initUrl'] is! String ||
          (out['initUrl'] as String).isEmpty) {
        return null;
      }
      // A shared QR must only ever open a web page. Reject `javascript:`,
      // `data:`, `file:`, `about:`, etc. — the receiver would otherwise
      // navigate a fresh isolated site to attacker-chosen script/local
      // content the moment it hydrates. File-import sites are device-local
      // and never ride a QR, so http(s)-only loses nothing shareable.
      final uri = Uri.tryParse((out['initUrl'] as String).trim());
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return out;
    } on FormatException {
      return null;
    }
  }

  /// The proxy the apply path installs for a decoded payload, read through
  /// the same `UserProxySettings.fromJson` so the review dialog cannot
  /// disagree with it. Null when the payload sets no proxy.
  static UserProxySettings? reviewProxy(Map<String, dynamic> qr) {
    final json = qr['proxySettings'];
    if (json is! Map) return null;
    final proxy = UserProxySettings.fromJson(<String, dynamic>{
      for (final e in json.entries)
        if (e.key is String) e.key as String: e.value,
    });
    return proxy.type == ProxyType.DEFAULT ? null : proxy;
  }

  static _ParsedQr? _parse(String input) {
    final prefix = '$_scheme://$_path/v';
    if (!input.startsWith(prefix)) return null;
    final tail = input.substring(prefix.length);
    final slash = tail.indexOf('/');
    if (slash <= 0) return null;
    final version = int.tryParse(tail.substring(0, slash));
    if (version == null || version < 1 || version > currentVersion) {
      return null;
    }
    final payload = tail.substring(slash + 1);
    if (payload.isEmpty) return null;
    return _ParsedQr(version: version, payload: payload);
  }
}

class _ParsedQr {
  final int version;
  final String payload;
  _ParsedQr({required this.version, required this.payload});
}
