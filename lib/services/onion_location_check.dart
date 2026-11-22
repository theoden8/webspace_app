/// The check that asks a site's home address, through the site's own Tor
/// route, which onion address it announces (ONION-001).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/host_user_agent.dart';
import 'package:webspace/services/onion_location.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/outbound_http_types.dart';

/// How much of the home page is read for the meta tag: the head of any page
/// worth announcing from fits well inside it.
const int kOnionCheckMaxBytes = 256 * 1024;

const Duration _timeout = Duration(seconds: 30);

/// GET [homeUrl] through [proxy], which must carry Tor (ONION-007), following
/// redirects only to targets [withinSite] admits and never from https down to
/// http, and read the answer's announcement (ONION-001).
Future<OnionCheck> checkOnionLocation(
  String homeUrl, {
  required OutboundProxy proxy,
  required bool Function(Uri target) withinSite,
}) async {
  assert(proxy.carriesTor, 'an onion check runs only on a Tor route');
  if (!proxy.carriesTor) return const OnionCheckFailed('not on Tor');
  final url = Uri.tryParse(homeUrl);
  if (url == null) return const OnionCheckFailed('no home address');
  var answeredBy = url;
  try {
    final outcome = await followPageSteered<_Answer>(
      proxy.resolved,
      url: url,
      follow: PageSteeredFollow<_Answer>(
        permit: (target) async =>
            (target.scheme == 'https' || target.scheme == 'http') &&
            withinSite(target),
        read: _readHead,
        onRedirect: (to) => answeredBy = to,
        forbidHttpsDowngrade: true,
        timeout: _timeout,
        userAgent: HostBrowser.sentUserAgent,
      ),
    );
    switch (outcome) {
      case PageSteeredRefused(:final reason):
        return OnionCheckFailed(reason);
      case PageSteeredValue(value: final answer):
        if (answer.status < 200 || answer.status >= 300) {
          return OnionCheckFailed('status ${answer.status}');
        }
        final endpoint = announcedEndpoint(
          answeredBy: answeredBy,
          header: answer.header,
          document: answer.document,
        );
        return endpoint == null
            ? const NothingAnnounced()
            : OnionAnnounced(endpoint);
    }
  } on http.ClientException catch (e) {
    return OnionCheckFailed('$e');
  } on IOException catch (e) {
    return OnionCheckFailed('$e');
  } on TimeoutException catch (e) {
    return OnionCheckFailed('$e');
  }
}

typedef _Answer = ({int status, String? header, String document});

/// The final answer's status, header and document up to the end of its head,
/// at most [kOnionCheckMaxBytes].
Future<_Answer> _readHead(http.StreamedResponse response) async {
  final bytes = BytesBuilder(copy: false);
  if (response.statusCode >= 200 && response.statusCode < 300) {
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length >= kOnionCheckMaxBytes) break;
      if (_endsHead(chunk)) break;
    }
  }
  return (
    status: response.statusCode,
    header: response.headers['onion-location'],
    document: utf8.decode(bytes.takeBytes(), allowMalformed: true),
  );
}

final _headEnd = RegExp('</head|<body', caseSensitive: false);

bool _endsHead(List<int> chunk) =>
    _headEnd.hasMatch(latin1.decode(chunk, allowInvalid: true));
