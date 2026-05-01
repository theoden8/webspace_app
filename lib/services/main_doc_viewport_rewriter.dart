// Android-only helper invoked from `shouldInterceptRequest` for
// main-document navigations when desktop-mode is on. Re-fetches the
// page through the per-site outbound proxy, rewrites
// `<meta name="viewport">` in the HTML body to `width=1366`, and
// returns the modified response so the WebView's HTML parser sees the
// desktop viewport at parse time.
//
// Why this exists: Android Chromium WebView does NOT recompute layout
// when the meta viewport content is mutated post-parse, so the JS-side
// shim's MutationObserver rewrite (which iOS WKWebView honours) only
// changes the attribute string. The layout viewport stays at the
// device's CSS width and React Native Web sites (Bluesky and similar)
// pick the mobile branch off `window.innerWidth` and CSS `(max-width:
// …)` queries. Rewriting the meta on the wire — before the parser
// reads it — is the only way to actually move the layout viewport.
//
// The cost: every desktop-mode main-doc navigation goes through Dart
// instead of native networking. Sub-resources (images, scripts,
// fetch/XHR) are NOT routed here — `shouldInterceptRequest` only
// fires for main-document navigations on modern Chromium WebView (see
// CLAUDE.md), and the native FastSubresourceInterceptor still handles
// DNS blocking + LocalCDN replacement for everything else.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:http/http.dart' as http;

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Synthetic viewport `content` value injected into the rewritten HTML.
/// Must clear the widest "desktop" breakpoint a mainstream site uses;
/// Bluesky's `useWebMediaQueries` gates `isDesktop` on `(min-width:
/// 1300px)`, so anything <=1299 ships the tablet layout.
const String desktopViewportContent = 'width=1366, initial-scale=1.0';

const String _viewportMetaReplacement =
    '<meta name="viewport" content="$desktopViewportContent">';

/// Matches `<meta name="viewport" ...>` in any attribute order, with
/// or without quotes, case-insensitive. Captures the entire tag so we
/// can substitute the canonical replacement.
final RegExp _viewportMetaRe = RegExp(
  r'''<meta\b[^>]*?\bname\s*=\s*["']?viewport["']?[^>]*?>''',
  caseSensitive: false,
  dotAll: true,
);

/// Matches the opening `<head>` tag (with or without attributes) so
/// we can inject a viewport meta when the page ships none.
final RegExp _headOpenRe = RegExp(
  r'<head\b[^>]*>',
  caseSensitive: false,
);

/// Default timeout for the upstream fetch. Pages slower than this fall
/// back to the WebView's native fetch (returning `null` from
/// `shouldInterceptRequest`).
const Duration _fetchTimeout = Duration(seconds: 30);

/// Functional core: rewrite [html] so the first/all viewport metas
/// carry [desktopViewportContent]. Pure — no I/O, easy to test.
String rewriteViewportMetaInHtml(String html) {
  if (_viewportMetaRe.hasMatch(html)) {
    return html.replaceAll(_viewportMetaRe, _viewportMetaReplacement);
  }
  // No viewport meta — inject one as the first child of <head> so
  // the parser reads it before any other head content.
  final headMatch = _headOpenRe.firstMatch(html);
  if (headMatch == null) {
    // Pages without <head> fall through unchanged. The WebView will
    // synthesise one and the page will get the platform default
    // viewport, which is what would have happened anyway.
    return html;
  }
  return html.replaceFirst(_headOpenRe, '${headMatch.group(0)}$_viewportMetaReplacement');
}

/// Side-effecting wrapper around [rewriteViewportMetaInHtml]: re-fetch
/// the URL via [outboundHttp], modify the HTML body if applicable, and
/// return a [WebResourceResponse] the WebView feeds to its HTML parser.
///
/// Returns `null` for any path we can't safely handle — the WebView
/// then falls through to its own native fetch:
///
///   * non-http(s) URL (file://, data:, blob:, etc.)
///   * non-GET method (POST navigations, form submits — these need
///     request body forwarding which Dart can't trivially do for
///     multipart and we'd rather not break login flows).
///   * sub-resource (`isForMainFrame == false`) — the native
///     FastSubresourceInterceptor handles those.
///   * the per-site / global proxy is blocked / fail-closed (returning
///     `null` lets the WebView surface its own ERR_PROXY_* page rather
///     than serving a blank document).
///   * network error / timeout — same reasoning.
///
/// For non-HTML responses (PDF, image, JSON, etc.) we return the raw
/// bytes verbatim. Letting the WebView re-fetch would double the
/// bandwidth, and we already paid for the request.
Future<inapp.WebResourceResponse?> rewriteMainDocForDesktopViewport(
  inapp.WebResourceRequest request, {
  required UserProxySettings? proxySettings,
  http.Client? clientOverride,
}) async {
  if (request.isForMainFrame == false) return null;

  final urlStr = request.url.toString();
  final uri = Uri.tryParse(urlStr);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;

  final method = (request.method ?? 'GET').toUpperCase();
  if (method != 'GET') return null;

  final http.Client client;
  if (clientOverride != null) {
    client = clientOverride;
  } else {
    final effective = proxySettings != null
        ? resolveEffectiveProxy(proxySettings)
        : GlobalOutboundProxy.current;
    final result = outboundHttp.clientFor(effective);
    if (result is OutboundClientBlocked) return null;
    client = (result as OutboundClientReady).client;
  }

  http.Response response;
  try {
    final req = http.Request(method, uri);
    // Forward the WebView's request headers verbatim — UA, Cookie,
    // Sec-CH-UA-*, Accept-Language, etc. Drop Accept-Encoding so the
    // http package auto-decompresses to plain bytes (we re-emit the
    // body without Content-Encoding below).
    final original = request.headers ?? const <String, String>{};
    original.forEach((k, v) {
      if (k.toLowerCase() == 'accept-encoding') return;
      req.headers[k] = v;
    });
    final streamed = await client.send(req).timeout(_fetchTimeout);
    response = await http.Response.fromStream(streamed);
  } catch (_) {
    return null;
  }

  final contentType = _firstHeader(response.headers, 'content-type') ?? '';
  final mime = _mimeOf(contentType);
  final charset = _charsetOf(contentType);

  Uint8List body = response.bodyBytes;
  if (mime == 'text/html' || mime == 'application/xhtml+xml') {
    final decoded = _decode(body, charset);
    final rewritten = rewriteViewportMetaInHtml(decoded);
    body = _encode(rewritten, charset);
  }

  return inapp.WebResourceResponse(
    contentType: mime ?? 'text/html',
    contentEncoding: charset ?? 'utf-8',
    data: body,
    statusCode: response.statusCode,
    reasonPhrase: response.reasonPhrase ?? 'OK',
    // Forward upstream headers so Set-Cookie, Cache-Control, CSP, etc.
    // flow through to the WebView's native handling. Drop the ones
    // that no longer apply after rewrite.
    headers: _passThroughHeaders(response.headers),
  );
}

Map<String, String> _passThroughHeaders(Map<String, String> upstream) {
  final out = <String, String>{};
  upstream.forEach((k, v) {
    final lk = k.toLowerCase();
    // Body length and encoding change after rewrite; let the WebView
    // recompute. Transfer-Encoding: chunked is meaningless for a
    // buffered Uint8List response.
    if (lk == 'content-length' ||
        lk == 'content-encoding' ||
        lk == 'transfer-encoding') {
      return;
    }
    out[k] = v;
  });
  return out;
}

String? _firstHeader(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

String? _mimeOf(String contentType) {
  if (contentType.isEmpty) return null;
  final semi = contentType.indexOf(';');
  final raw = semi >= 0 ? contentType.substring(0, semi) : contentType;
  final trimmed = raw.trim().toLowerCase();
  return trimmed.isEmpty ? null : trimmed;
}

String? _charsetOf(String contentType) {
  if (contentType.isEmpty) return null;
  final m =
      RegExp(r'charset\s*=\s*"?([^\s;"]+)"?', caseSensitive: false)
          .firstMatch(contentType);
  return m?.group(1)?.toLowerCase();
}

String _decode(Uint8List bytes, String? charset) {
  switch (charset) {
    case 'latin-1':
    case 'iso-8859-1':
      return latin1.decode(bytes);
    case 'ascii':
    case 'us-ascii':
      return ascii.decode(bytes, allowInvalid: true);
    case 'utf-8':
    case 'utf8':
    case null:
      return utf8.decode(bytes, allowMalformed: true);
    default:
      // Unknown charset — best-effort UTF-8. Real CJK pages use
      // explicit charset; this branch is for the rare exotic.
      return utf8.decode(bytes, allowMalformed: true);
  }
}

Uint8List _encode(String html, String? charset) {
  switch (charset) {
    case 'latin-1':
    case 'iso-8859-1':
      return Uint8List.fromList(latin1.encode(html));
    case 'ascii':
    case 'us-ascii':
      return Uint8List.fromList(ascii.encode(html));
    default:
      return Uint8List.fromList(utf8.encode(html));
  }
}
