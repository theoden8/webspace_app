import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

/// Encode/decode the QR-shareable subset of a [WebViewModel] JSON dict.
///
/// The QR payload intentionally carries only non-secret per-site
/// configuration. Excluded by design: `cookies` (incl. secure cookies),
/// `userScripts`, `enabledGlobalScriptIds`, `blockedCookies`, `siteId`
/// (receiver mints fresh), `currentUrl`/`pageTitle` (runtime state).
/// Proxy passwords never leave the device — `UserProxySettings.toJson`
/// strips them per `proxy-password-secure-storage` (PWD-005).
///
/// Wire format: `webspace://qr/site/v1/<base64url>` where the payload is
/// gzip-compressed UTF-8 JSON. base64url padding is stripped on encode and
/// reapplied on decode.
///
/// When you add a new per-site field to [WebViewModel], decide whether it
/// belongs in [includedKeys]. The drift test in
/// `test/site_settings_qr_codec_test.dart` fails on any unknown key in
/// `toJson` so an unreviewed field cannot silently flow into shared QRs.
class SiteSettingsQrCodec {
  SiteSettingsQrCodec._();

  static const int currentVersion = 1;
  static const String _scheme = 'webspace';
  static const String _path = 'qr/site';

  /// Per-site keys the QR is allowed to carry.
  static const Set<String> includedKeys = {
    'initUrl',
    'name',
    'proxySettings',
    'javascriptEnabled',
    'userAgent',
    'thirdPartyCookiesEnabled',
    'incognito',
    'alwaysOpenHome',
    'kioskMode',
    'language',
    'zoomPercent',
    'clearUrlEnabled',
    'dnsBlockEnabled',
    'contentBlockEnabled',
    'trackingProtectionEnabled',
    'localCdnEnabled',
    'blockAutoRedirects',
    'fullscreenMode',
    'htmlCachingEnabled',
    'notificationsEnabled',
    'locationMode',
    'spoofLatitude',
    'spoofLongitude',
    'spoofAccuracy',
    'spoofTimezone',
    'spoofTimezoneFromLocation',
    'liveLocationGranularity',
    'webRtcPolicy',
  };

  /// Per-site keys deliberately stripped on share. Listed so the drift
  /// test can detect a brand-new key that the dev forgot to classify.
  static const Set<String> excludedKeys = {
    'siteId',
    'currentUrl',
    'pageTitle',
    'cookies',
    'userScripts',
    'enabledGlobalScriptIds',
    'blockedCookies',
    // Base64 PNG bytes: would blow QR capacity, and an icon is
    // device-local cosmetics, not shareable configuration.
    'customIconPng',
  };

  /// Strip a full `WebViewModel.toJson()` to the QR-shareable subset.
  static Map<String, dynamic> shareableSubset(Map<String, dynamic> fullJson) {
    final out = <String, dynamic>{};
    for (final k in includedKeys) {
      if (fullJson.containsKey(k)) out[k] = fullJson[k];
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
    final compressed = gzip.encode(utf8.encode(jsonStr));
    final payload = base64Url.encode(compressed).replaceAll('=', '');
    return '$_scheme://$_path/v$currentVersion/$payload';
  }

  /// Decode a `webspace://qr/site/vN/<payload>` URI back to a shareable
  /// subset. Returns null if the input is malformed, the version is newer
  /// than [currentVersion], the payload fails gunzip, or `initUrl` is
  /// missing. Any keys outside [includedKeys] in a successfully decoded
  /// payload are dropped — a hostile sender cannot smuggle, e.g.,
  /// `cookies` past the receiver's strip filter.
  // A per-site settings payload is a few hundred bytes; these ceilings leave
  // generous headroom while bounding a decompression bomb.
  static const int _kMaxCompressedBytes = 64 * 1024;
  static const int _kMaxDecodedBytes = 256 * 1024;

  /// Gzip-inflate [compressed], feeding it in small chunks and aborting the
  /// moment the running output exceeds [maxOut]. Returns null on overflow or
  /// malformed input, so a bomb never fully materializes in memory.
  static List<int>? _gunzipBounded(List<int> compressed, int maxOut) {
    final out = BytesBuilder(copy: false);
    var total = 0;
    var overflow = false;
    final counting = _CountingByteSink((chunk) {
      total += chunk.length;
      if (total > maxOut) {
        overflow = true;
      } else {
        out.add(chunk);
      }
    });
    try {
      final conv = gzip.decoder.startChunkedConversion(counting);
      const step = 4096;
      for (var i = 0; i < compressed.length && !overflow; i += step) {
        final end = (i + step < compressed.length) ? i + step : compressed.length;
        conv.add(compressed.sublist(i, end));
      }
      conv.close();
    } catch (_) {
      return null;
    }
    return overflow ? null : out.takeBytes();
  }

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
      final bytes = _gunzipBounded(compressed, _kMaxDecodedBytes);
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
    } catch (_) {
      return null;
    }
  }

  /// True if [input] looks like a webspace QR URI (any version).
  static bool looksLikeQrPayload(String input) {
    return _parse(input.trim()) != null;
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

/// Byte sink that forwards each inflated chunk to [onData], letting the
/// caller tally the running output and abort a decompression bomb before
/// it fully materializes.
class _CountingByteSink extends ByteConversionSink {
  final void Function(List<int>) onData;
  _CountingByteSink(this.onData);

  @override
  void add(List<int> chunk) => onData(chunk);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    onData(chunk.sublist(start, end));
  }

  @override
  void close() {}
}
