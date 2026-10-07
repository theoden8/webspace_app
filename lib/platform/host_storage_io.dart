import 'dart:io' as io;

import 'package:path_provider/path_provider.dart' as pp;

export 'package:webspace/services/file_store_io.dart' show createFileStore;
export 'package:webspace/services/tor_geoip_io.dart' show createTorGeoIpStore;
export 'package:webspace/services/tor_socks_probe_io.dart'
    show createTorSocksProbe, createExternalTorIdentify;

/// Read a cache file from the app documents directory, or null when absent.
Future<String?> hostReadDocumentText(String name) async {
  final dir = await pp.getApplicationDocumentsDirectory();
  final file = io.File('${dir.path}/$name');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> hostWriteDocumentText(String name, String contents) async {
  final dir = await pp.getApplicationDocumentsDirectory();
  await io.File('${dir.path}/$name').writeAsString(contents);
}

Future<String> hostDocumentsPath() async =>
    (await pp.getApplicationDocumentsDirectory()).path;
