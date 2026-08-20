import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Direct (unproxied) client for downloads, with gzip auto-decompression
/// DISABLED so the server's Content-Length survives to the caller. Unchanged
/// from when this lived inline in DownloadEngine.
http.Client createDirectDownloadClient() {
  final httpClient = HttpClient();
  httpClient.autoUncompress = false;
  return IOClient(httpClient);
}
