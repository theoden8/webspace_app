import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/tor_geoip.dart';
import 'package:webspace/settings/proxy.dart';

TorGeoIpStore? createTorGeoIpStore() => IoTorGeoIpStore();

const String _logTag = 'TorGeoIP';

/// [TorGeoIpStore] over `<app cache>/tor_geoip/`.
///
/// The cache directory rather than documents: the table is re-downloadable,
/// so it stays out of device backups, and the OS reclaiming it under storage
/// pressure costs one download on the next pin.
class IoTorGeoIpStore implements TorGeoIpStore {
  IoTorGeoIpStore({Directory? overrideRoot, DateTime Function()? clock})
      : _overrideRoot = overrideRoot,
        _clock = clock ?? DateTime.now;

  final Directory? _overrideRoot;
  final DateTime Function() _clock;
  Future<TorGeoIpTable?>? _inFlight;

  Future<Directory> _directory() async {
    final root = _overrideRoot ?? await getApplicationCacheDirectory();
    return Directory('${root.path}/tor_geoip');
  }

  @override
  Future<TorGeoIpTable?> newest() async {
    final dir = await _directory();
    if (!await dir.exists()) return null;
    TorGeoIpTable? best;
    await for (final entry in dir.list()) {
      if (entry is! File) continue;
      final at = torGeoIpFetchedAt(entry.uri.pathSegments.last);
      if (at == null) continue;
      if (best == null || at.isAfter(best.fetchedAt)) {
        best = TorGeoIpTable(entry.path, at);
      }
    }
    return best;
  }

  @override
  Future<TorGeoIpTable?> download(UserProxySettings via) =>
      _inFlight ??= _download(via).whenComplete(() => _inFlight = null);

  Future<TorGeoIpTable?> _download(UserProxySettings via) async {
    final result = outboundHttp.clientFor(via);
    if (result is OutboundClientBlocked) {
      LogService.instance.log(_logTag, 'Download blocked: ${result.reason}',
          level: LogLevel.warning);
      return null;
    }
    final client = (result as OutboundClientReady).client;
    try {
      for (final url in kTorGeoIpUrls) {
        final host = Uri.parse(url).host;
        try {
          final response =
              await client.get(Uri.parse(url)).timeout(kTorGeoIpTimeout);
          if (response.statusCode != 200) {
            LogService.instance.log(
                _logTag, '$host answered HTTP ${response.statusCode}',
                level: LogLevel.warning);
            continue;
          }
          final bytes = response.bodyBytes;
          if (!await Isolate.run(() => _isTable(bytes))) {
            LogService.instance.log(
                _logTag,
                '$host answered ${bytes.length} bytes that are not a GeoIP '
                'table under $kTorGeoIpLicence',
                level: LogLevel.warning);
            continue;
          }
          final table = await _keep(bytes);
          LogService.instance.log(
              _logTag, 'Fetched ${bytes.length} bytes from $host',
              level: LogLevel.info);
          return table;
        } catch (e) {
          LogService.instance.log(_logTag, '$host failed: $e',
              level: LogLevel.warning);
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  static bool _isTable(Uint8List bytes) {
    try {
      return isTorGeoIpTable(utf8.decode(bytes));
    } on FormatException {
      return false;
    }
  }

  /// Write under a fresh name, then drop every other file. Written to a
  /// `.part` first so a crash mid-write never leaves a half table that
  /// [newest] would hand to tor.
  Future<TorGeoIpTable> _keep(Uint8List bytes) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final at = _clock();
    final name = torGeoIpFileName(at);
    final part = File('${dir.path}/$name.part');
    await part.writeAsBytes(bytes, flush: true);
    final file = await part.rename('${dir.path}/$name');
    await for (final entry in dir.list()) {
      if (entry.path == file.path) continue;
      try {
        await entry.delete();
      } catch (_) {}
    }
    return TorGeoIpTable(
        file.path, DateTime.fromMillisecondsSinceEpoch(
            at.toUtc().millisecondsSinceEpoch, isUtc: true));
  }
}
