// Third-party code from: https://github.com/marcjoha/favicon
//
// MIT License
//
// Copyright (c) 2019 Marcus Johansson
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'dart:typed_data';

import 'package:html/parser.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/untrusted_image.dart';
import 'package:webspace/services/url_host.dart';

// Signatures from https://en.wikipedia.org/wiki/List_of_file_signatures
const ICO_SIG = [0, 0, 1, 0];
const PNG_SIG = [137, 80, 78, 71, 13, 10, 26, 10];

class Favicon implements Comparable<Favicon> {
  String url;
  int width;
  int height;

  Favicon(this.url, {this.width = 0, this.height = 0});

  @override
  int compareTo(Favicon other) {
    // If both are vector graphics, use URL length as tie-breaker
    if (url.endsWith('.svg') && other.url.endsWith('.svg')) {
      return url.length < other.url.length ? -1 : 1;
    }

    // Sort vector graphics before bitmaps
    if (url.endsWith('.svg')) return -1;
    if (other.url.endsWith('.svg')) return 1;

    // If bitmap size is the same, use URL length as tie-breaker
    if (width * height == other.width * other.height) {
      return url.length < other.url.length ? -1 : 1;
    }

    return (width * height > other.width * other.height) ? -1 : 1;
  }

  @override
  String toString() {
    return '{Url: $url, width: $width, height: $height}';
  }
}

class FaviconFinder {
  /// Fetch a list of favicons for [url].
  ///
  /// [proxy] is the per-site proxy of the site whose favicon is being
  /// fetched, resolved through the per-site → global precedence ladder.
  /// When null, the app-global outbound proxy applies. When the resolved
  /// proxy cannot be honored from Dart-side (e.g. SOCKS5, or Tor not yet
  /// up), every network step is short-circuited and null is returned, since
  /// the site was not asked — falling back to a direct connection would
  /// defeat the proxy and leak the IP. Null too when the page came back with
  /// an error and no icon was found: the site did not say it has none.
  static Future<List<Favicon>?> getAll(
    String url, {
    List<String>? suffixes,
    required OutboundProxy proxy,
  }) async {
    var favicons = <Favicon>[];
    var iconUrls = <String>[];
    if (Host.ofWebUrl(url) == null) return favicons;

    final effectiveProxy = proxy.resolved;
    final clientResult = outboundHttp.clientFor(effectiveProxy);
    if (clientResult is! OutboundClientReady) {
      return null; // proxy could not be honored — fail closed
    }
    final client = SiteUserAgentClient(clientResult.client,
        userAgent: HostBrowser.sentUserAgent);

    try {
    final page = await _fetchPage(Uri.parse(url), client: client);
    if (page == null) return favicons;
    // A relative link is relative to the document that declared it, which a
    // redirect can put on another host.
    final uri = page.url;
    var document = parse(page.body);

    for (var rel in ['icon', 'shortcut icon']) {
      for (var iconTag in document.querySelectorAll("link[rel='$rel']")) {
        if (iconTag.attributes['href'] != null) {
          var iconUrl = iconTag.attributes['href']!.trim();

          // Fix scheme relative URLs
          if (iconUrl.startsWith('//')) {
            iconUrl = uri.scheme + ':' + iconUrl;
          }

          // Fix relative URLs
          if (iconUrl.startsWith('/')) {
            iconUrl = uri.scheme + '://' + uri.host + ":" + uri.port.toString() + iconUrl;
          }

          // Fix naked URLs
          if (!iconUrl.startsWith('http')) {
            iconUrl = uri.scheme + '://' + uri.host + ":" + uri.port.toString() + '/' + iconUrl;
          }

          iconUrl = iconUrl.split('?').first;

          if (await _verifyImage(iconUrl, client: client)) {
            iconUrls.add(iconUrl);
          }
        }
      }
    }

    for (final origin in page.faviconOrigins) {
      final iconUrl = origin.replace(path: '/favicon.ico').toString();
      if (await _verifyImage(iconUrl, client: client)) {
        iconUrls.add(iconUrl);
      }
    }

    iconUrls = iconUrls.toSet().toList();

    if (suffixes != null) {
      iconUrls.removeWhere((url) => !suffixes.contains(url.split('.').last));
    }

    for (var iconUrl in iconUrls) {
      // No need for size calculation on vector images
      if (iconUrl.endsWith('.svg')) {
        favicons.add(Favicon(iconUrl));
        continue;
      }

      // Image library lacks read support for Ico, assume standard size
      // https://github.com/brendan-duncan/image/issues/212
      if (iconUrl.endsWith('.ico')) {
        favicons.add(Favicon(iconUrl, width: 16, height: 16));
        continue;
      }

      var image = decodeUntrustedImage(
          (await client.get(Uri.parse(iconUrl))).bodyBytes);
      if (image != null) {
        favicons
            .add(Favicon(iconUrl, width: image.width, height: image.height));
      }
    }

    if (favicons.isEmpty && !page.ok) return null;
    return favicons..sort();
    } finally {
      client.close();
    }
  }

  /// The document at [first] once its redirects are followed, at most
  /// [_maxRedirects], or null on a redirect to a non-http(s) URL or one too
  /// many. [faviconOrigins] are where its `/favicon.ico` is looked for: the
  /// site's own origin, and the first other host a redirect sends it to.
  /// gmail.com answers with a 301 to mail.google.com, whose favicon is
  /// Gmail's, and that redirects on to a sign-in page on a third host whose
  /// favicon is not.
  static Future<({Uri url, String body, bool ok, List<Uri> faviconOrigins})?>
      _fetchPage(
      Uri first,
      {required http.Client client}) async {
    final origins = [_origin(first)];
    var target = first;
    for (var hop = 0;; hop++) {
      final response = await http.Response.fromStream(await client
          .send(http.Request('GET', target)..followRedirects = false));
      final location = response.headers['location'];
      if (!_redirectStatuses.contains(response.statusCode) ||
          location == null) {
        return (
          url: target,
          body: response.body,
          ok: response.statusCode >= 200 && response.statusCode < 300,
          faviconOrigins: origins,
        );
      }
      final next = target.resolve(location);
      if (hop >= _maxRedirects || Host.ofWebUrl(next.toString()) == null) {
        return null;
      }
      if (origins.length == 1 && next.host != first.host) {
        origins.add(_origin(next));
      }
      target = next;
    }
  }

  static Uri _origin(Uri url) => Uri(
      scheme: url.scheme, host: url.host, port: url.hasPort ? url.port : null);

  static const int _maxRedirects = 5;
  static const Set<int> _redirectStatuses = {301, 302, 303, 307, 308};

  static Future<bool> _verifyImage(String url,
      {required http.Client client}) async {
    // A link the fix-ups above leave without a host (`href="http:x.png"`):
    // dart:io refuses it with an ArgumentError.
    if (Host.ofWebUrl(url) == null) return false;
    var response = await client.get(Uri.parse(url));

    var contentType = response.headers['content-type'];
    if (contentType == null || !contentType.contains('image')) return false;

    // Take extra care with ico's since they might be constructed manually
    if (url.endsWith('.ico')) {
      if (response.bodyBytes.length < 4) return false;

      if (!_verifySignature(response.bodyBytes, signature: ICO_SIG) &&
          !_verifySignature(response.bodyBytes, signature: PNG_SIG)) {
        return false;
      }
    }

    return response.statusCode == 200 &&
        (response.contentLength ?? 0) > 0 &&
        contentType.contains('image');
  }

  static bool _verifySignature(Uint8List bodyBytes,
      {required List<int> signature}) {
    if (bodyBytes.length < signature.length) return false;
    var fileSignature = bodyBytes.sublist(0, signature.length);
    for (var i = 0; i < fileSignature.length; i++) {
      if (fileSignature[i] != signature[i]) return false;
    }
    return true;
  }
}
