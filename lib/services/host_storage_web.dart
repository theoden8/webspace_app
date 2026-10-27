import 'package:webspace/services/external_tor_runtime.dart'
    show ExternalTorIdentify;
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/tor_control_link.dart'
    show TorControlConnect, TorCookieRead;
import 'package:webspace/services/tor_engine.dart' show TorSocksProbe;
import 'package:webspace/services/tor_geoip.dart' show TorGeoIpStore;

/// No app directories on web; cache-backed services run empty.
FileStore createFileStore(String directoryName, {required StoreKind kind}) =>
    MemoryFileStore();

/// No Tor runtime on web: no GeoIP table to keep and no listener to ask.
TorGeoIpStore? createTorGeoIpStore() => null;
TorSocksProbe? createTorSocksProbe() => null;
ExternalTorIdentify? createExternalTorIdentify() => null;
TorControlConnect? createTorControlConnect() => null;
TorCookieRead? createTorCookieRead() => null;

/// No cache directory on web: downloaded caches simply stay empty, which
/// leaves the depending services in their no-data state.
Future<String?> hostReadCacheText(String name) async => null;

Future<void> hostWriteCacheText(String name, {required String contents}) async {}

/// No app directories on web: path-backed stores read as empty.
Future<String> hostEntryPath(String name, {required StoreKind kind}) async =>
    '';
