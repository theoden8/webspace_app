import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:webspace/services/outbound_http.dart';

/// The app-wide proxy's GET as extension sources answer it: a JSON [replies]
/// body or a package's [files] by URL, a 404 for anything else, and
/// [failing] as every request's transport failure while set.
class FakeExtensionFetch {
  final Map<String, Object?> replies = {};
  final Map<String, Uint8List> files = {};
  String? failing;

  /// Every URL asked for, in order.
  final List<Uri> asked = [];

  Future<AppProxyFetch> call(Uri url, {required int maxBytes}) async {
    asked.add(url);
    if (failing case final reason?) return FetchFailed(reason);
    if (files[url.toString()] case final bytes?) {
      return bytes.length > maxBytes
          ? const FetchFailed('over the size limit')
          : Fetched(http.Response.bytes(bytes, 200));
    }
    if (replies.containsKey(url.toString())) {
      return Fetched(
        http.Response.bytes(utf8.encode(jsonEncode(replies[url.toString()])), 200),
      );
    }
    return const FetchFailed('HTTP 404');
  }
}
