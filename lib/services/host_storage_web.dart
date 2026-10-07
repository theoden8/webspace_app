import 'package:webspace/services/external_tor_runtime.dart'
    show ExternalTorIdentify;
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/tor_engine.dart' show TorSocksProbe;
import 'package:webspace/services/tor_geoip.dart' show TorGeoIpStore;

/// No documents directory on web; cache-backed services run empty.
FileStore createFileStore(String directoryName) => MemoryFileStore();

/// No Tor runtime on web: no GeoIP table to keep and no listener to ask.
TorGeoIpStore? createTorGeoIpStore() => null;
TorSocksProbe? createTorSocksProbe() => null;
ExternalTorIdentify? createExternalTorIdentify() => null;

/// No documents directory on web: downloaded caches simply stay empty, which
/// leaves the depending services in their no-data state.
Future<String?> hostReadDocumentText(String name) async => null;

Future<void> hostWriteDocumentText(String name, String contents) async {}

/// No documents directory on web: path-backed caches read as empty.
Future<String> hostDocumentsPath() async => '';
