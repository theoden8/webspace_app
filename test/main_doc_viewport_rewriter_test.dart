import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:webspace/services/main_doc_viewport_rewriter.dart';

void main() {
  group('rewriteViewportMetaInHtml', () {
    test('replaces a width=device-width meta with the desktop value', () {
      // Bluesky's actual viewport — full-fat with extra parameters.
      const html = '<!doctype html><html><head>'
          '<meta name="viewport" content="width=device-width, '
          'initial-scale=1, minimum-scale=1, viewport-fit=cover">'
          '</head><body></body></html>';
      final out = rewriteViewportMetaInHtml(html);
      expect(
        out,
        contains('<meta name="viewport" content="$desktopViewportContent">'),
      );
      expect(out, isNot(contains('width=device-width')));
      expect(out, isNot(contains('viewport-fit=cover')));
    });

    test('handles attribute order with content before name', () {
      // HTML allows any attribute order. Many sites ship it the
      // unusual way and our regex must catch it.
      const html = '<head><meta content="width=device-width" name="viewport">'
          '</head>';
      final out = rewriteViewportMetaInHtml(html);
      expect(
        out,
        contains('<meta name="viewport" content="$desktopViewportContent">'),
      );
    });

    test('case-insensitive match (META, NAME, VIEWPORT)', () {
      const html = '<HEAD><META NAME="VIEWPORT" CONTENT="width=device-width">'
          '</HEAD>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, contains(desktopViewportContent));
      expect(out, isNot(contains('width=device-width')));
    });

    test('replaces ALL viewport metas, not just the first', () {
      // Some build tools emit duplicates. Chromium honours the LAST
      // one, so missing a duplicate would defeat the rewrite.
      const html = '<head>'
          '<meta name="viewport" content="width=device-width">'
          '<meta name="viewport" content="width=device-width, initial-scale=2">'
          '</head>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, isNot(contains('width=device-width')));
      // Both metas were rewritten to the same canonical form.
      final occurrences =
          desktopViewportContent.allMatches(out).length;
      expect(occurrences, 2);
    });

    test('injects a viewport meta when the page ships none', () {
      // Plain HTML without a viewport meta — Chrome WebView falls
      // back to a narrow viewport on a phone, which gives the same
      // mobile layout we're trying to escape. Inject one ourselves.
      const html = '<!doctype html><html><head>'
          '<title>No viewport here</title></head><body></body></html>';
      final out = rewriteViewportMetaInHtml(html);
      expect(
        out,
        contains('<head><meta name="viewport" content="$desktopViewportContent">'),
      );
      // Existing head content is preserved.
      expect(out, contains('<title>No viewport here</title>'));
    });

    test('preserves <head> attributes when injecting', () {
      // <head> can carry attributes (xmlns, lang). The regex must
      // keep them rather than collapsing to a bare <head>.
      const html = '<html><head profile="https://example/profile">'
          '</head></html>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, contains('<head profile="https://example/profile"><meta'));
    });

    test('no <head> → unchanged', () {
      // Quirks-mode pages without <head>. Adding a meta floating
      // above the document would do nothing useful; bail.
      const html = '<html><body><p>Hi</p></body></html>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, equals(html));
    });

    test('matches viewport meta with single quotes', () {
      const html = "<head><meta name='viewport' "
          "content='width=device-width'></head>";
      final out = rewriteViewportMetaInHtml(html);
      expect(out, contains(desktopViewportContent));
      expect(out, isNot(contains('width=device-width')));
    });

    test('matches viewport meta with no quotes around name', () {
      // HTML5 allows unquoted attribute values for tokens.
      const html = '<head><meta name=viewport content="width=device-width">'
          '</head>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, contains(desktopViewportContent));
    });

    test('tolerates extra whitespace around attributes', () {
      const html = '<head><meta   name = "viewport"   '
          'content = "width=device-width"></head>';
      final out = rewriteViewportMetaInHtml(html);
      expect(out, contains(desktopViewportContent));
    });

    test('does NOT match unrelated metas', () {
      const html = '<head>'
          '<meta name="description" content="width=device-width nope">'
          '<meta name="viewport" content="width=device-width">'
          '</head>';
      final out = rewriteViewportMetaInHtml(html);
      // The description meta keeps its content (we don't touch it
      // even though it contains the substring "width=device-width").
      expect(out, contains('name="description" content="width=device-width nope"'));
      // The viewport meta is rewritten.
      expect(out.contains('width=1366'), isTrue);
    });
  });

  group('rewriteMainDocForDesktopViewport', () {
    test('main-frame=false → null (sub-resources go through native)', () async {
      final result = await rewriteMainDocForDesktopViewport(
        _request(
          url: 'https://example.test/',
          isForMainFrame: false,
        ),
        proxySettings: null,
        clientOverride: _failingClient(),
      );
      expect(result, isNull);
    });

    test('non-http(s) scheme → null', () async {
      // file://, data:, blob: should fall through to native handling
      // — `outboundHttp` only knows how to fetch http/https.
      for (final url in [
        'data:text/html,<html></html>',
        'file:///tmp/x.html',
        'blob:https://example.test/abc',
      ]) {
        final result = await rewriteMainDocForDesktopViewport(
          _request(url: url),
          proxySettings: null,
          clientOverride: _failingClient(),
        );
        expect(result, isNull, reason: 'expected null for $url');
      }
    });

    test('non-GET method → null (POST navigations need body forwarding)',
        () async {
      // Form submits and other POST navigations would need request
      // body forwarding which isn't trivial to do for multipart. Punt
      // to native rather than break logins.
      final result = await rewriteMainDocForDesktopViewport(
        _request(url: 'https://example.test/', method: 'POST'),
        proxySettings: null,
        clientOverride: _failingClient(),
      );
      expect(result, isNull);
    });

    test('text/html body has the viewport rewritten', () async {
      // End-to-end happy path: GET → 200 text/html → rewrite the
      // viewport meta in the body and return a WebResourceResponse
      // with status/headers preserved.
      const sourceHtml = '<!doctype html><html><head>'
          '<meta name="viewport" content="width=device-width, initial-scale=1">'
          '<title>x</title></head><body>x</body></html>';
      final fake = http_testing.MockClient((req) async {
        expect(req.url.toString(), 'https://example.test/');
        expect(req.method, 'GET');
        // Forwarded headers reach the upstream.
        expect(req.headers['User-Agent'], contains('Firefox'));
        expect(req.headers['Cookie'], 'sid=1');
        return http.Response(sourceHtml, 200,
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'set-cookie': 'sid=2; Path=/',
            },
            reasonPhrase: 'OK');
      });
      final result = await rewriteMainDocForDesktopViewport(
        _request(
          url: 'https://example.test/',
          headers: {
            'User-Agent': 'Mozilla/5.0 ... Firefox/147.0',
            'Cookie': 'sid=1',
          },
        ),
        proxySettings: null,
        clientOverride: fake,
      );
      expect(result, isNotNull);
      expect(result!.statusCode, 200);
      expect(result.contentType, 'text/html');
      expect(result.contentEncoding, 'utf-8');
      final body = utf8.decode(result.data!);
      expect(body, contains(desktopViewportContent));
      expect(body, isNot(contains('width=device-width')));
      // Set-Cookie flows through so login state isn't dropped.
      expect(result.headers?['set-cookie'], 'sid=2; Path=/');
    });

    test('non-HTML body passes through unchanged', () async {
      // PDFs, images, JSON downloaded as the main doc must NOT be
      // rewritten — the regex would corrupt binary content.
      final binary = Uint8List.fromList(List.generate(64, (i) => i));
      final fake = http_testing.MockClient((_) async => http.Response.bytes(
            binary, 200,
            headers: {'content-type': 'application/pdf'},
            reasonPhrase: 'OK',
          ));
      final result = await rewriteMainDocForDesktopViewport(
        _request(url: 'https://example.test/file.pdf'),
        proxySettings: null,
        clientOverride: fake,
      );
      expect(result, isNotNull);
      expect(result!.contentType, 'application/pdf');
      expect(result.data, equals(binary));
    });

    test('upstream network error → null', () async {
      final fake = http_testing.MockClient((_) async {
        throw http.ClientException('boom');
      });
      final result = await rewriteMainDocForDesktopViewport(
        _request(url: 'https://example.test/'),
        proxySettings: null,
        clientOverride: fake,
      );
      expect(result, isNull);
    });

    test('drops Content-Length / Content-Encoding from passthrough headers',
        () async {
      // Body length differs after rewrite, and we already let `http`
      // decompress on read, so re-emitting Content-Length /
      // Content-Encoding would lie to the WebView.
      const html = '<head><meta name="viewport" content="width=device-width">'
          '</head>';
      final fake = http_testing.MockClient((_) async => http.Response(html, 200,
          headers: {
            'content-type': 'text/html; charset=utf-8',
            'content-length': '999',
            'content-encoding': 'gzip',
            'transfer-encoding': 'chunked',
            'cache-control': 'no-cache',
          },
          reasonPhrase: 'OK'));
      final result = await rewriteMainDocForDesktopViewport(
        _request(url: 'https://example.test/'),
        proxySettings: null,
        clientOverride: fake,
      );
      final hs = result!.headers!;
      expect(hs.containsKey('content-length'), isFalse);
      expect(hs.containsKey('content-encoding'), isFalse);
      expect(hs.containsKey('transfer-encoding'), isFalse);
      // Other headers are preserved.
      expect(hs['cache-control'], 'no-cache');
    });

    test('strips Accept-Encoding before forwarding', () async {
      // We let `http` auto-decompress on read, so requesting
      // gzipped content from upstream is fine — but we need to drop
      // Accept-Encoding so the upstream doesn't send a compressed
      // body we'd then have to decompress manually.
      late http.BaseRequest seen;
      final fake = http_testing.MockClient((req) async {
        seen = req;
        return http.Response('<head></head>', 200,
            headers: {'content-type': 'text/html'}, reasonPhrase: 'OK');
      });
      await rewriteMainDocForDesktopViewport(
        _request(
          url: 'https://example.test/',
          headers: {'Accept-Encoding': 'gzip', 'User-Agent': 'x'},
        ),
        proxySettings: null,
        clientOverride: fake,
      );
      expect(seen.headers.containsKey('Accept-Encoding'), isFalse);
      expect(seen.headers['User-Agent'], 'x');
    });

    test('latin-1 body decode/re-encode round trip preserves bytes', () async {
      // Some legacy pages still ship ISO-8859-1. Rewriting through
      // utf8 would mangle the body; the helper detects charset and
      // round-trips through the matching codec.
      final latinBody = '<head><meta name="viewport" '
          'content="width=device-width">café</head>';
      final bytes = Uint8List.fromList(latin1.encode(latinBody));
      final fake = http_testing.MockClient((_) async => http.Response.bytes(
            bytes, 200,
            headers: {'content-type': 'text/html; charset=iso-8859-1'},
            reasonPhrase: 'OK',
          ));
      final result = await rewriteMainDocForDesktopViewport(
        _request(url: 'https://example.test/'),
        proxySettings: null,
        clientOverride: fake,
      );
      // Decoding through latin-1 should preserve the é byte.
      final decoded = latin1.decode(result!.data!);
      expect(decoded, contains('café'));
      expect(decoded, contains(desktopViewportContent));
    });
  });
}

inapp.WebResourceRequest _request({
  required String url,
  String method = 'GET',
  bool isForMainFrame = true,
  Map<String, String>? headers,
}) {
  return inapp.WebResourceRequest(
    url: inapp.WebUri(url),
    method: method,
    isForMainFrame: isForMainFrame,
    headers: headers,
  );
}

http.Client _failingClient() => http_testing.MockClient((_) async {
      throw StateError('client should not have been called');
    });
