import 'dart:io' as io;

import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/file_store_io.dart';

export 'package:webspace/services/file_store_io.dart' show createFileStore;
export 'package:webspace/services/managed_tor_io.dart'
    show createManagedTorRuntime, managedTorNotices;
export 'package:webspace/services/tor_control_io.dart'
    show createTorControlConnect, createTorCookieRead;
export 'package:webspace/services/tor_geoip_io.dart' show createTorGeoIpStore;
export 'package:webspace/services/tor_socks_probe_io.dart'
    show createTorSocksProbe, createExternalTorIdentify;

/// Read the cache entry [name], or null when absent.
Future<String?> hostReadCacheText(String name) async {
  final file = io.File(await hostEntryPath(name, kind: StoreKind.cache));
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> hostWriteCacheText(String name, {required String contents}) async {
  final file = io.File(await hostEntryPath(name, kind: StoreKind.cache));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

/// The path of the entry [name], a file or a directory, in the directory
/// [kind] names.
Future<String> hostEntryPath(String name, {required StoreKind kind}) =>
    appEntryPath(name, kind: kind);
