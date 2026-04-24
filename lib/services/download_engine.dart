import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
class DownloadEngine {
  final http.Client _client;

  DownloadEngine({http.Client? client}) : _client = client ?? http.Client();

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

  Future<DownloadResult> fetch({
    required String url,
    String? cookieHeader,
    String? userAgent,
    String? suggestedFilename,
    String? mimeTypeHint,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      throw DownloadException('Invalid URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw DownloadException('Unsupported scheme: ${uri.scheme}');
    }

    final headers = <String, String>{};
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      headers['cookie'] = cookieHeader;
    }
    if (userAgent != null && userAgent.isNotEmpty) {
      headers['user-agent'] = userAgent;
    }

    final http.Response response;
    try {
      response = await _client.get(uri, headers: headers);
    } catch (e) {
      throw DownloadException('Network error: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DownloadException('HTTP ${response.statusCode}');
    }

    final contentType = response.headers['content-type'];
    final mime = contentType == null ? mimeTypeHint : _parseMime(contentType);

    return DownloadResult(
      bytes: response.bodyBytes,
      filename: deriveFilename(
        suggested: suggestedFilename,
        url: url,
        mimeType: mime,
      ),
      mimeType: mime,
    );
  }

  static String _sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1f]'), '')
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
  }) {
    final Uint8List bytes;
    try {
      bytes = base64.decode(base64Data.trim());
    } on FormatException catch (e) {
      throw DownloadException('Malformed base64: ${e.message}');
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
