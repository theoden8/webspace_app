import 'dart:io' as io;

import 'package:webspace/services/file_store_io.dart';

export 'package:webspace/services/file_store_io.dart' show createFileStore;
export 'package:webspace/services/tor_control_io.dart'
    show createTorControlConnect, createTorCookieRead;
export 'package:webspace/services/tor_geoip_io.dart' show createTorGeoIpStore;
export 'package:webspace/services/tor_socks_probe_io.dart'
    show createTorSocksProbe, createExternalTorIdentify;

/// Read a cache file from the app documents directory, or null when absent.
Future<String?> hostReadDocumentText(String name) async {
  final dir = await documentsDirectory();
  final file = io.File('${dir.path}/$name');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> hostWriteDocumentText(String name,
    {required String contents}) async {
  final dir = await documentsDirectory();
  await io.File('${dir.path}/$name').writeAsString(contents);
}

Future<String> hostDocumentsPath() async =>
    (await documentsDirectory()).path;
