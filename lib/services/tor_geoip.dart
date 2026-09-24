// tor's GeoIP table, fetched on the device rather than shipped.
//
// A country pin (`ExitNodes {cc}`, TOR-014) is resolved against tor's IPv4
// GeoIP table; without one the pin matches no relay at all. Tor.framework
// can bundle the table, but the data is the IPFire Location Database under
// CC BY-SA 4.0, and copyleft data never goes into a release artifact
// (LICENSE-002). So the device downloads it from the Tor Project, over Tor,
// the first time a pin needs it, and keeps it verbatim, licence header and
// all, in the app's cache directory.
//
// tor has no updater of its own: it reads the file named by `GeoIPFile` at
// start and again only when that path changes. A refresh is therefore a new
// file under a new name, never an overwrite.
//
// Pure Dart, no dart:io: the store behind [TorGeoIpStore] is in
// tor_geoip_io.dart.

import 'package:webspace/settings/proxy.dart';

/// Where the table comes from, in order. Both are fetched through Tor.
///
/// The onion service first: it is the Tor Project's own GitLab
/// (onion.torproject.org), reached without an exit relay, so no exit sees
/// the request and the answer is authenticated by the address itself. The
/// clearnet host is the fallback, through an exit, for when the onion
/// service is unreachable. Both serve tor's `main`, which its maintainers
/// regenerate from the IPFire database.
const List<String> kTorGeoIpUrls = [
  'http://eweiibe6tdjsdprb4px6rqrzzcsi22m4koia44kc5pcjr7nec2rlxyad.onion'
      '/tpo/core/tor/-/raw/main/src/config/geoip',
  'https://gitlab.torproject.org/tpo/core/tor/-/raw/main/src/config/geoip',
];

/// SOCKS username the download rides, so it gets a circuit of its own and
/// is never linked to a site's (TOR-003).
const String kTorGeoIpTag = '__webspace_tor_geoip__';

/// Age past which a pin refreshes the table in the background. Relays rarely
/// change country, so a month-old table still places them; it is kept in use
/// until the new one lands.
const Duration kTorGeoIpMaxAge = Duration(days: 30);

/// Per-URL budget for the download: about 10 MB through a Tor circuit.
const Duration kTorGeoIpTimeout = Duration(seconds: 120);

/// The licence the table must declare in its own header. A table under any
/// other terms is refused: accepting it would mean running on data nobody
/// reviewed the licence of.
const String kTorGeoIpLicence = 'CC BY-SA 4.0';

/// Fewer rows than this is a truncated or placeholder answer. The table has
/// about 400,000.
const int kTorGeoIpMinRows = 100000;

/// A table on disk.
class TorGeoIpTable {
  const TorGeoIpTable(this.path, this.fetchedAt);

  /// Absolute path, as tor's `GeoIPFile` takes it.
  final String path;
  final DateTime fetchedAt;

  bool isStale(DateTime now) => now.difference(fetchedAt) > kTorGeoIpMaxAge;
}

/// On-device store for the table.
abstract class TorGeoIpStore {
  /// The newest table kept, or null when there is none.
  Future<TorGeoIpTable?> newest();

  /// Download a fresh table through [via], keep it, and drop older ones.
  /// Null when every source failed or answered with something that is not
  /// a table. A download already in flight is joined, not repeated.
  Future<TorGeoIpTable?> download(UserProxySettings via);
}

final RegExp _row = RegExp(r'^\d+,\d+,([A-Z]{2}|\?\?)$');
final RegExp _licenceLine = RegExp(
  '^#\\s*License:\\s*${RegExp.escape(kTorGeoIpLicence)}\\s*\$',
);

/// Whether [text] is tor's IPv4 GeoIP table under [kTorGeoIpLicence]:
/// `#` comments, one of which is the licence line, then `low,high,CC` rows.
/// One malformed row refuses the whole file, since tor would stop reading
/// at it.
bool isTorGeoIpTable(String text) {
  var rows = 0;
  var licensed = false;
  var start = 0;
  while (start < text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    var line = text.substring(start, end);
    start = end + 1;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      if (_licenceLine.hasMatch(line)) licensed = true;
      continue;
    }
    if (!_row.hasMatch(line)) return false;
    rows++;
  }
  return licensed && rows >= kTorGeoIpMinRows;
}

const String _fileNamePrefix = 'geoip-';

/// File name for a table fetched at [at]. Unique per download, so tor sees
/// a new path and reloads (it never re-reads a path it already read).
String torGeoIpFileName(DateTime at) =>
    '$_fileNamePrefix${at.toUtc().millisecondsSinceEpoch}';

/// When the table in [name] was fetched, or null when [name] is not one.
DateTime? torGeoIpFetchedAt(String name) {
  if (!name.startsWith(_fileNamePrefix)) return null;
  final millis = int.tryParse(name.substring(_fileNamePrefix.length));
  if (millis == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
