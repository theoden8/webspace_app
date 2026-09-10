import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/download_client.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// Result of a successful download fetch.
class DownloadResult {
  final Uint8List bytes;
  final String filename;
  final String? mimeType;

  DownloadResult({
    required this.bytes,
    required this.filename,
    this.mimeType,
  });
}

/// Thrown when a download cannot be completed.
class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => 'DownloadException: $message';
}

/// Fetches an HTTP(S) URL with optional forwarded cookies and user-agent,
/// returning the response body as bytes plus a derived filename. I/O goes
/// through an injectable [http.Client] so tests can supply a fake.
///
/// When [proxy] is provided, the client routes through it via the global
/// [outboundHttp] factory (HTTP/HTTPS via dart:io's findProxy, SOCKS5 via
/// the socks5_proxy package's TCP tunnel). If the proxy address is
/// malformed, [fetch] throws [DownloadException] rather than fall back to
/// direct, which would leak the device IP.
class DownloadEngine {
  /// Hard ceiling on both the wire bytes buffered in memory and the
  /// decompressed body. The whole download is held in RAM before it is
  /// written to disk, so without a bound a hostile server can OOM the app
  /// two ways: an endless stream, or a tiny `Content-Encoding: gzip` body
  /// that inflates to gigabytes (a decompression bomb). This is a crash
  /// guard, not a product policy — it sits far above any realistic file.
  static const int defaultMaxBytes = 2 * 1024 * 1024 * 1024;

  /// Redirect hops followed before the download is refused.
  static const int maxRedirects = 5;

  final http.Client _client;
  final OutboundClient? _outboundResult;
  final int _maxBytes;

  DownloadEngine({
    http.Client? client,
    UserProxySettings? proxy,
    int maxBytes = defaultMaxBytes,
  })  : _client = client ?? _defaultClient(proxy),
        _maxBytes = maxBytes,
        _outboundResult = client == null && proxy != null
            ? outboundHttp.clientFor(resolveEffectiveProxy(proxy))
            : null;

  /// Default HTTP client with gzip auto-decompression DISABLED so the
  /// server's Content-Length survives to the caller. When
  /// `autoUncompress: true` (the dart:io default), the client adds
  /// `Accept-Encoding: gzip` and then strips Content-Length from the
  /// response headers after decompression — leaving the progress ring
  /// indeterminate even for servers that know how big the download is.
  ///
  /// When [proxy] is non-null and non-DEFAULT (or when the caller-provided
  /// `proxy` resolves through the global to non-DEFAULT), the client routes
  /// through that proxy via [outboundHttp]. If the proxy address is
  /// malformed, a stub client is returned that will fail any subsequent
  /// request — see [_blockedClient] / [fetch].
  static http.Client _defaultClient(UserProxySettings? proxy) {
    if (proxy != null) {
      final resolved = resolveEffectiveProxy(proxy);
      if (resolved.type != ProxyType.DEFAULT) {
        final result = outboundHttp.clientFor(resolved);
        if (result is OutboundClientReady) return result.client;
        if (result is OutboundClientBlocked) {
          return _BlockedHttpClient(result.reason);
        }
      }
    }
    return createDirectDownloadClient();
  }

  /// RFC 6265 `Cookie:` header value from an ordered list of name/value
  /// pairs. Returns null if no pairs were supplied.
  static String? buildCookieHeader(
      Iterable<MapEntry<String, String>> cookies) {
    final parts = cookies
        .map((e) => '${e.key}=${e.value}')
        .toList(growable: false);
    return parts.isEmpty ? null : parts.join('; ');
  }

  /// Derives a filename from (in priority): [suggested] → last non-empty
  /// URL path segment → `download` + extension guessed from [mimeType].
  /// The result is sanitized so path separators and control chars never
  /// escape the downloads directory.
  static String deriveFilename({
    String? suggested,
    required String url,
    String? mimeType,
  }) {
    final s = (suggested ?? '').trim();
    if (s.isNotEmpty) return _sanitize(s);

    try {
      final uri = Uri.parse(url);
      for (int i = uri.pathSegments.length - 1; i >= 0; i--) {
        final seg = uri.pathSegments[i];
        if (seg.trim().isEmpty) continue;
        final decoded = Uri.decodeComponent(seg);
        if (decoded.trim().isNotEmpty) return _sanitize(decoded);
      }
    } catch (_) {}

    final ext = _extensionForMime(mimeType);
    return 'download${ext ?? ''}';
  }

  /// Fetch [url], following up to [maxRedirects] redirects by hand.
  ///
  /// `dart:io` copies every header of the previous request onto a
  /// `Location` target with no origin comparison, so an authenticated
  /// download that 302s to another host would carry the site's session
  /// cookie (HttpOnly included), `referer` and UA there (DL-007). Each hop
  /// instead recomputes the cookie header: through [cookieHeaderFor] (the
  /// site's jar, asked for the new URL) when the caller supplies it,
  /// otherwise [cookieHeader] only while the hop stays on the first URL's
  /// origin. The referer is dropped on an origin change, and an https to
  /// http hop is refused outright.
  Future<DownloadResult> fetch({
    required String url,
    String? cookieHeader,
    Future<String?> Function(Uri url)? cookieHeaderFor,
    String? userAgent,
    String? referer,
    String? suggestedFilename,
    String? mimeTypeHint,
    void Function(int bytesDone, int? bytesTotal)? onProgress,
  }) async {
    final outboundResult = _outboundResult;
    if (outboundResult is OutboundClientBlocked) {
      throw DownloadException(outboundResult.reason);
    }
    final client = _client;
    if (client is _BlockedHttpClient) {
      throw DownloadException(client.reason);
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      throw DownloadException('Invalid URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw DownloadException('Unsupported scheme: ${uri.scheme}');
    }

    // Many download servers use Referer for hotlink protection; without
    // one they may 302 to an error page or stream HTML with no
    // Content-Length, which makes the progress ring spin indeterminately.
    // Only forward http(s) referers so we don't leak data: / file: URLs.
    var hopReferer = referer != null &&
            (referer.startsWith('http://') || referer.startsWith('https://'))
        ? referer
        : null;
    var current = uri;
    var hops = 0;
    http.StreamedResponse response;
    while (true) {
      final request = http.Request('GET', current)..followRedirects = false;
      final String? cookie;
      if (hops == 0) {
        cookie = cookieHeader;
      } else if (cookieHeaderFor != null) {
        cookie = await cookieHeaderFor(current);
      } else {
        cookie = _sameOrigin(current, uri) ? cookieHeader : null;
      }
      if (cookie != null && cookie.isNotEmpty) {
        request.headers['cookie'] = cookie;
      }
      if (userAgent != null && userAgent.isNotEmpty) {
        request.headers['user-agent'] = userAgent;
      }
      if (hopReferer != null) {
        request.headers['referer'] = hopReferer;
      }
      try {
        response = await _client.send(request);
      } catch (e) {
        throw DownloadException('Network error: $e');
      }
      if (!_isRedirect(response.statusCode)) break;
      final location = response.headers['location'];
      try {
        await response.stream.drain<void>();
      } catch (_) {}
      if (location == null || location.isEmpty) {
        throw DownloadException('HTTP ${response.statusCode}');
      }
      if (++hops > maxRedirects) {
        throw DownloadException('Too many redirects');
      }
      final next = current.resolve(location);
      if (next.scheme != 'http' && next.scheme != 'https') {
        throw DownloadException('Unsupported scheme: ${next.scheme}');
      }
      if (current.scheme == 'https' && next.scheme == 'http') {
        throw DownloadException('Redirect downgrades https to http');
      }
      if (!_sameOrigin(next, current)) hopReferer = null;
      current = next;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Drain the body so the connection can be returned to the pool.
      try {
        await response.stream.drain<void>();
      } catch (_) {}
      throw DownloadException('HTTP ${response.statusCode}');
    }

    final total = response.contentLength;
    if (total != null && total > _maxBytes) {
      try {
        await response.stream.drain<void>();
      } catch (_) {}
      throw DownloadException('Download exceeds size limit');
    }
    onProgress?.call(0, total);

    final chunks = <List<int>>[];
    var done = 0;
    try {
      await for (final chunk in response.stream) {
        done += chunk.length;
        if (done > _maxBytes) {
          throw DownloadException('Download exceeds size limit');
        }
        chunks.add(chunk);
        onProgress?.call(done, total);
      }
    } on DownloadException {
      rethrow;
    } catch (e) {
      throw DownloadException('Network error: $e');
    }

    final bytesReceived = Uint8List(done);
    var offset = 0;
    for (final c in chunks) {
      bytesReceived.setRange(offset, offset + c.length, c);
      offset += c.length;
    }

    // If the server compressed the response despite our not asking for
    // it (autoUncompress: false means we don't send Accept-Encoding),
    // decompress now. Progress tracking above is in wire bytes, which
    // matches Content-Length; the final DownloadResult exposes the
    // decoded body so the save-to-disk path writes usable files.
    final encoding =
        response.headers['content-encoding']?.trim().toLowerCase();
    final Uint8List bytes;
    try {
      bytes = switch (encoding) {
        'gzip' || 'x-gzip' => _inflateBounded(hostGzipDecoder, bytesReceived),
        'deflate' => _inflateBounded(hostZlibDecoder, bytesReceived),
        _ => bytesReceived,
      };
    } on FormatException catch (e) {
      throw DownloadException('Decompression failed: ${e.message}');
    }

    final contentType = response.headers['content-type'];
    final mime = contentType == null ? mimeTypeHint : _parseMime(contentType);

    return DownloadResult(
      bytes: bytes,
      filename: deriveFilename(
        suggested: suggestedFilename,
        url: url,
        mimeType: mime,
      ),
      mimeType: mime,
    );
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 ||
      status == 308;

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// Inflate [compressed] through [codec] in chunks, aborting the moment the
  /// running output exceeds [_maxBytes] so a decompression bomb never fully
  /// materializes. Throws [DownloadException] on overflow.
  Uint8List _inflateBounded(Converter<List<int>, List<int>> codec,
      Uint8List compressed) {
    final out = BytesBuilder(copy: false);
    var total = 0;
    var overflow = false;
    final sink = _CountingByteSink((chunk) {
      total += chunk.length;
      if (total > _maxBytes) {
        overflow = true;
      } else {
        out.add(chunk);
      }
    });
    final conv = codec.startChunkedConversion(sink);
    const step = 64 * 1024;
    for (var i = 0; i < compressed.length && !overflow; i += step) {
      final end =
          (i + step < compressed.length) ? i + step : compressed.length;
      conv.add(compressed.sublist(i, end));
    }
    conv.close();
    if (overflow) {
      throw DownloadException('Download exceeds size limit');
    }
    return out.takeBytes();
  }

  static String _sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1f]'), '')
        // Bidi controls reorder the rendered name without changing the bytes,
        // so a page can suggest "invoice\u202Egnp.exe" and have the save
        // dialog and file manager both show "invoiceexe.png".
        .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '')
        .trim();
  }

  /// Decodes a `data:` URI into bytes + filename + mime. Supports both
  /// base64 (`data:<mime>;base64,<payload>`) and URL-encoded
  /// (`data:<mime>,<payload>`) forms, with or without a mime.
  static DownloadResult decodeDataUri({
    required String url,
    String? suggestedFilename,
  }) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'data') {
      throw DownloadException('Not a data URI: $url');
    }
    final data = UriData.fromUri(uri);
    final bytes = Uint8List.fromList(data.contentAsBytes());
    final mime = data.mimeType.isEmpty ? null : data.mimeType;
    // The data URI's "path" is the payload itself, which produces garbage
    // when fed to deriveFilename — pass an empty URL so it falls straight
    // through to the mime-based fallback.
    return DownloadResult(
      bytes: bytes,
      filename: deriveFilename(
        suggested: suggestedFilename,
        url: '',
        mimeType: mime,
      ),
      mimeType: mime,
    );
  }

  /// Wraps a base64 payload (e.g. from a blob:→FileReader round-trip) in a
  /// [DownloadResult]. The payload is the bare base64 string — no
  /// `data:<mime>;base64,` prefix.
  static DownloadResult fromBase64({
    required String base64Data,
    String? suggestedFilename,
    String? mimeType,
    String? sourceUrl,
    int maxBytes = defaultMaxBytes,
  }) {
    final trimmed = base64Data.trim();
    // The blob-download bridge handler is page-reachable, so a hostile page
    // could hand us an arbitrarily large base64 string. Unlike fetch(), this
    // decodes straight into RAM, so bound it. Estimate the decoded size from
    // the base64 length (4 chars -> 3 bytes) and reject before materializing.
    if (trimmed.length ~/ 4 * 3 > maxBytes) {
      throw DownloadException('Download exceeds size limit');
    }
    final Uint8List bytes;
    try {
      bytes = base64.decode(trimmed);
    } on FormatException catch (e) {
      throw DownloadException('Malformed base64: ${e.message}');
    }
    if (bytes.length > maxBytes) {
      throw DownloadException('Download exceeds size limit');
    }
    return DownloadResult(
      bytes: bytes,
      filename: deriveFilename(
        suggested: suggestedFilename,
        url: sourceUrl ?? '',
        mimeType: mimeType,
      ),
      mimeType: mimeType,
    );
  }

  static String? _parseMime(String contentType) {
    final semi = contentType.indexOf(';');
    return (semi == -1 ? contentType : contentType.substring(0, semi)).trim();
  }

  static String? _extensionForMime(String? mime) {
    if (mime == null) return null;
    switch (mime) {
      case 'application/pdf':
        return '.pdf';
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/svg+xml':
        return '.svg';
      case 'text/html':
        return '.html';
      case 'text/plain':
        return '.txt';
      case 'text/csv':
        return '.csv';
      case 'application/json':
        return '.json';
      case 'application/zip':
        return '.zip';
      case 'application/octet-stream':
        return null;
    }
    return null;
  }
}

/// Byte sink that forwards each inflated chunk to [onData] so the caller
/// can tally the running output and abort a decompression bomb early.
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

/// Sentinel client returned by [DownloadEngine._defaultClient] when the
/// configured proxy cannot be honored from Dart-side. Any request through
/// it raises [DownloadException] before touching the network so we never
/// leak the device IP via a direct fallback.
class _BlockedHttpClient extends http.BaseClient {
  final String reason;
  _BlockedHttpClient(this.reason);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw DownloadException(reason);
  }
}
