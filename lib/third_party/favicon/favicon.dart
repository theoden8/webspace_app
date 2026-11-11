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
import 'package:meta/meta.dart';

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
    final siteHost = Host.ofWebUrl(url);
    if (siteHost == null) return favicons;

    final effectiveProxy = proxy.resolved;
    // Favicon URLs come from page markup; every fetch below runs through the one
    // guarded redirect follower, which judges each hop's destination address as
    // it connects and pins to it (SEC-049, BUG-012). The site's own host is the
    // one whose private address is allowed, so a site the user keeps on their
    // LAN still serves its favicon. One guarded client serves the whole
    // discovery (the page, every icon-link check and every /favicon.ico probe):
    // a page with several icon links otherwise pays a fresh handshake per fetch,
    // most of the budget under Tor or SOCKS. It judges and pins every hop
    // exactly as a per-fetch client would, and is closed when discovery ends,
    // cutting any socket it still holds.
    return withPageSteeredClient(
      effectiveProxy,
      allowPrivateHost: siteHost,
      timeout: _discoveryTimeout,
      body: (client) async {
        final ({Uri url, String body, bool ok, List<Uri> faviconOrigins}) page;
        switch (await _fetchPage(Uri.parse(url), client: client)) {
          case PageSteeredRefused(:final kind):
            // The proxy could not be honoured → fail closed, so the site is asked
            // again later; a refused redirect or non-web URL → nothing was
            // reached, so there are no icons (an empty list, not a retry).
            return kind == PageSteeredRefusal.clientUnavailable ? null : favicons;
          case PageSteeredValue(:final value):
            page = value;
        }

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

          final bytes = await _imageBytes(iconUrl, client: client);
          final image = bytes == null ? null : decodeUntrustedImage(bytes);
          if (image != null) {
            favicons
                .add(Favicon(iconUrl, width: image.width, height: image.height));
          }
        }

        if (favicons.isEmpty && !page.ok) return null;
        return favicons..sort();
      },
    );
  }

  /// A deadline for the whole discovery. The fetches share one client (so no
  /// single fetch can close it), so the bound lives on [withPageSteeredClient],
  /// which closes the shared client when it fires and cuts any open socket.
  static Duration _discoveryTimeout = const Duration(seconds: 15);

  /// Shorten the discovery deadline in a test, so a page that never finishes is
  /// driven without the 15s wait; reset with [resetDiscoveryTimeout].
  @visibleForTesting
  static set discoveryTimeout(Duration d) => _discoveryTimeout = d;

  @visibleForTesting
  static void resetDiscoveryTimeout() =>
      _discoveryTimeout = const Duration(seconds: 15);

  /// A favicon image larger than this is not a favicon: the capped read stops
  /// and the icon is dropped, so a hostile page cannot stream an unbounded body
  /// back through the discovery.
  static const _maxIconBytes = 2 * 1024 * 1024;

  /// Follow a favicon fetch's redirects through the one guarded follower
  /// (SEC-049, BUG-012), reusing [client] so a discovery's several fetches share
  /// a connection pool, and draping the site's User-Agent. The guarded connect
  /// judges every hop's address; [permit] only keeps each hop a valid web URL.
  /// No per-fetch deadline: a reused client cannot be closed per fetch, so the
  /// discovery-wide deadline on [withPageSteeredClient] bounds and cuts them.
  static Future<PageSteeredOutcome<T>> _followFavicon<T>(
    Uri url, {
    required PageSteeredHttp client,
    required Future<T> Function(http.StreamedResponse response) read,
    void Function(Uri to)? onRedirect,
  }) =>
      followPageSteeredReusing(
        client,
        url: url,
        follow: PageSteeredFollow<T>(
          permit: (target) async => Host.ofWebUrl(target.toString()) != null,
          read: read,
          maxRedirects: _maxRedirects,
          onRedirect: onRedirect,
          userAgent: HostBrowser.sentUserAgent,
        ),
      );

  /// The bytes of the icon at [url], or null when the fetch was refused, not a
  /// 200, or larger than [_maxIconBytes].
  static Future<Uint8List?> _imageBytes(String url,
      {required PageSteeredHttp client}) async {
    if (Host.ofWebUrl(url) == null) return null;
    final outcome = await _followFavicon<Uint8List?>(
      Uri.parse(url),
      client: client,
      read: pageSteeredCappedBytes(_maxIconBytes),
    );
    return outcome is PageSteeredValue<Uint8List?> ? outcome.value : null;
  }

  /// The document at [first] once its redirects are followed through the guarded
  /// follower, at most [_maxRedirects]; refused on a redirect to a non-web URL or
  /// one too many (SEC-049, BUG-012). [faviconOrigins] are where its
  /// `/favicon.ico` is looked for: the site's own origin, and the first other
  /// host a redirect sends it to. gmail.com answers with a 301 to
  /// mail.google.com, whose favicon is Gmail's, and that redirects on to a
  /// sign-in page on a third host whose favicon is not.
  static Future<
          PageSteeredOutcome<
              ({Uri url, String body, bool ok, List<Uri> faviconOrigins})>>
      _fetchPage(
    Uri first, {
    required PageSteeredHttp client,
  }) {
    final origins = [_origin(first)];
    // The document the chain lands on, which a relative icon link resolves
    // against (ICON-002); tracked through the redirect hook rather than the
    // response's request, which a test transport need not carry.
    var landed = first;
    return _followFavicon<
        ({Uri url, String body, bool ok, List<Uri> faviconOrigins})>(
      first,
      client: client,
      onRedirect: (to) {
        landed = to;
        if (origins.length == 1 && to.host != first.host) {
          origins.add(_origin(to));
        }
      },
      // http.Response.fromStream decodes with the response's declared charset
      // and falls back to latin1, so a windows-1251 / Shift_JIS / latin1 home
      // page (or one with a non-UTF-8 byte and no charset) parses rather than
      // throwing a FormatException that would lose the icon (ICON path).
      read: (response) async {
        final full = await http.Response.fromStream(response);
        return (
          url: landed,
          body: full.body,
          ok: full.statusCode >= 200 && full.statusCode < 300,
          faviconOrigins: origins,
        );
      },
    );
  }

  static Uri _origin(Uri url) => Uri(
      scheme: url.scheme, host: url.host, port: url.hasPort ? url.port : null);

  static const int _maxRedirects = 5;

  static Future<bool> _verifyImage(String url,
      {required PageSteeredHttp client}) async {
    // A link the fix-ups above leave without a host (`href="http:x.png"`):
    // dart:io refuses it with an ArgumentError.
    if (Host.ofWebUrl(url) == null) return false;
    final outcome = await _followFavicon<http.Response>(
      Uri.parse(url),
      client: client,
      read: http.Response.fromStream,
    );
    if (outcome is! PageSteeredValue<http.Response>) return false;
    final response = outcome.value;

    final contentType = response.headers['content-type'];
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
