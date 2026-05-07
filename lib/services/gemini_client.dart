import 'dart:async';
import 'dart:convert';
import 'dart:io';

class GeminiResponse {
  final int status;
  final String meta;
  final String body;

  const GeminiResponse({
    required this.status,
    required this.meta,
    required this.body,
  });

  bool get isSuccess => status >= 20 && status < 30;
  bool get isRedirect => status >= 30 && status < 40;
  bool get isInput => status >= 10 && status < 20;
  bool get isError => status >= 40;

  String get mimeType {
    if (!isSuccess) return '';
    final parts = meta.split(';');
    return parts.first.trim().toLowerCase();
  }

  bool get isGemtext =>
      mimeType.isEmpty || mimeType == 'text/gemini';
}

class GeminiClient {
  static const int defaultPort = 1965;
  static const int maxRedirects = 5;
  static const Duration timeout = Duration(seconds: 10);
  static const int maxBodySize = 5 * 1024 * 1024; // 5 MB

  static Future<GeminiResponse> fetch(String url, {int redirects = 0}) async {
    if (redirects > maxRedirects) {
      return const GeminiResponse(
        status: 0,
        meta: 'Too many redirects',
        body: '',
      );
    }

    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'gemini') {
      return const GeminiResponse(
        status: 0,
        meta: 'Invalid Gemini URL',
        body: '',
      );
    }

    final host = uri.host;
    final port = uri.hasPort ? uri.port : defaultPort;

    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        host,
        port,
        timeout: timeout,
        onBadCertificate: (_) => true,
      );

      socket.write('$url\r\n');
      await socket.flush();

      final completer = Completer<GeminiResponse>();
      final chunks = <List<int>>[];
      var totalSize = 0;
      var headerParsed = false;
      var headerBytes = <int>[];
      int? status;
      String? meta;

      socket.listen(
        (data) {
          if (completer.isCompleted) return;

          if (!headerParsed) {
            headerBytes.addAll(data);
            final headerEnd = _findCrLf(headerBytes);
            if (headerEnd >= 0) {
              final headerLine = utf8.decode(headerBytes.sublist(0, headerEnd));
              final parsed = _parseHeader(headerLine);
              status = parsed.$1;
              meta = parsed.$2;
              headerParsed = true;

              final remaining = headerBytes.sublist(headerEnd + 2);
              if (remaining.isNotEmpty) {
                totalSize += remaining.length;
                chunks.add(remaining);
              }
            }
          } else {
            totalSize += data.length;
            if (totalSize > maxBodySize) {
              if (!completer.isCompleted) {
                completer.complete(GeminiResponse(
                  status: status!,
                  meta: meta!,
                  body: utf8.decode(
                    chunks.expand((c) => c).toList(),
                    allowMalformed: true,
                  ),
                ));
              }
              socket?.destroy();
              return;
            }
            chunks.add(data);
          }
        },
        onDone: () {
          if (completer.isCompleted) return;
          if (!headerParsed) {
            completer.complete(const GeminiResponse(
              status: 0,
              meta: 'Empty response',
              body: '',
            ));
            return;
          }
          final body = utf8.decode(
            chunks.expand((c) => c).toList(),
            allowMalformed: true,
          );
          completer.complete(GeminiResponse(
            status: status!,
            meta: meta!,
            body: body,
          ));
        },
        onError: (e) {
          if (!completer.isCompleted) {
            completer.complete(GeminiResponse(
              status: 0,
              meta: 'Connection error: $e',
              body: '',
            ));
          }
        },
      );

      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => const GeminiResponse(
          status: 0,
          meta: 'Response timeout',
          body: '',
        ),
      );

      if (response.isRedirect) {
        final redirectUrl = _resolveRedirect(url, response.meta);
        return fetch(redirectUrl, redirects: redirects + 1);
      }

      return response;
    } on SocketException catch (e) {
      return GeminiResponse(
        status: 0,
        meta: 'Connection failed: ${e.message}',
        body: '',
      );
    } on HandshakeException catch (e) {
      return GeminiResponse(
        status: 0,
        meta: 'TLS handshake failed: ${e.message}',
        body: '',
      );
    } on TimeoutException {
      return const GeminiResponse(
        status: 0,
        meta: 'Connection timeout',
        body: '',
      );
    } finally {
      socket?.destroy();
    }
  }

  static int _findCrLf(List<int> bytes) {
    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A) return i;
    }
    return -1;
  }

  static (int, String) _parseHeader(String header) {
    if (header.length < 2) return (0, 'Malformed header');
    final statusStr = header.substring(0, 2);
    final status = int.tryParse(statusStr);
    if (status == null) return (0, 'Malformed status: $statusStr');
    final meta = header.length > 3 ? header.substring(3).trim() : '';
    return (status, meta);
  }

  static String _resolveRedirect(String currentUrl, String target) {
    final targetUri = Uri.tryParse(target.trim());
    if (targetUri != null && targetUri.hasScheme) return target.trim();
    final base = Uri.parse(currentUrl);
    return base.resolve(target.trim()).toString();
  }

  static bool isGeminiUrl(String url) =>
      url.startsWith('gemini://');
}
