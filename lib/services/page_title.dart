import 'dart:async';

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

final Map<String, String?> _pageTitleCache = {};

/// The page title at [url], parsed from its HTML; null when the fetch fails
/// or the page has none. Cached per URL for the process.
///
/// LEAK-002: this is a network-bound fetch of a user-supplied URL, so it goes
/// through the outbound seam like every other Dart-side call. [proxy] is the
/// owning site's setting when there is one; a fresh add / inbound link has no
/// model yet and resolves through the global proxy. A blocked client aborts
/// the fetch — a direct GET would hand the URL's host the device IP, and the
/// URL can come straight from an attacker-authored share intent.
Future<String?> getPageTitle(String url, {UserProxySettings? proxy}) async {
  if (_pageTitleCache.containsKey(url)) {
    return _pageTitleCache[url];
  }

  final clientResult = outboundHttp.clientFor(
    resolveEffectiveProxy(
      proxy ?? UserProxySettings(type: ProxyType.DEFAULT),
      siteId: null,
    ),
  );
  if (clientResult is! OutboundClientReady) {
    LogTag.title.warning(
        'Outbound blocked: ${(clientResult as OutboundClientBlocked).reason}');
    return null;
  }
  final client = clientResult.client;
  try {
    final response = await client.get(Uri.parse(url)).timeout(
      Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Page fetch timeout'),
    );

    if (response.statusCode == 200) {
      html_dom.Document document = html_parser.parse(response.body);
      final titleElement = document.querySelector('title');
      if (titleElement != null) {
        final title = titleElement.text.trim();
        if (title.isNotEmpty) {
          _pageTitleCache[url] = title;
          return title;
        }
      }
    }
  } catch (e) {
    // Silently handle errors
  } finally {
    client.close();
  }

  _pageTitleCache[url] = null;
  return null;
}
