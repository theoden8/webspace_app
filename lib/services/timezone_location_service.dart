import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log_service.dart';

/// Default download URL: the latest `timezones-now` GeoJSON zip from
/// `evansiroky/timezone-boundary-builder`. ~7–15 MB compressed, ~30–60 MB
/// uncompressed. Each Feature has `properties.tzid` (IANA name) and a
/// `geometry` of type Polygon or MultiPolygon.
const String _defaultUrl =
    'https://github.com/evansiroky/timezone-boundary-builder/releases/latest/download/timezones-now.geojson.zip';

const String _cacheFileName = 'tz_polygons.geojson';
const String _urlPrefKey = 'tz_polygons_url';
const String _lastUpdatedPrefKey = 'tz_polygons_last_updated';

/// One zone's polygon set, prepared for fast point-in-polygon lookup.
class _ZoneEntry {
  final String tzid;
  // Each polygon is a list of rings; the first ring is the outer boundary,
  // the rest are holes. Each ring is a flat list of [lng, lat, lng, lat,
  // ...] for cache locality.
  final List<List<Float64List>> polygons;
  // Bounding box of the zone (minLng, minLat, maxLng, maxLat) — used to
  // skip polygons whose bbox doesn't contain the query point. Without this
  // every lookup would do PiP against ~hundreds of zones.
  final double minLng, minLat, maxLng, maxLat;

  _ZoneEntry(this.tzid, this.polygons, this.minLng, this.minLat,
      this.maxLng, this.maxLat);
}

/// Singleton service for downloading, caching, and querying a GeoJSON
/// timezone-polygon dataset. Used by the per-site location settings to
/// expose a "From picked location" timezone option, which resolves the
/// IANA zone of the user's spoofed coordinates at shim build time.
///
/// Pattern matches [DnsBlockService] / [ContentBlockerService] /
/// [LocalCdnService]: the data is opt-in (the user must explicitly tap
/// "Download timezone data" in app settings), persists across launches in
/// app private storage, and notifies listeners on change so dependent UI
/// (the per-site dropdown) can re-evaluate.
class TimezoneLocationService {
  static TimezoneLocationService? _instance;
  static TimezoneLocationService get instance =>
      _instance ??= TimezoneLocationService._();

  TimezoneLocationService._();

  List<_ZoneEntry>? _zones;
  bool _loadAttempted = false;

  /// True iff a polygon dataset is parsed and ready for lookups.
  bool get isReady => _zones != null && _zones!.isNotEmpty;

  /// Number of IANA zones in the loaded dataset (0 if not loaded).
  int get zoneCount => _zones?.length ?? 0;

  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void _notifyListeners() {
    for (final l in List<VoidCallback>.from(_listeners)) {
      l();
    }
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_cacheFileName');
  }

  /// Configured download URL (user-overridable in app settings).
  Future<String> getUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_urlPrefKey) ?? _defaultUrl;
  }

  /// Persist a new download URL. Does not trigger a download — the user
  /// must press "Download" again to fetch from the new URL.
  Future<void> setUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlPrefKey, url);
  }

  /// Last successful download timestamp, or null if never downloaded.
  Future<DateTime?> getLastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_lastUpdatedPrefKey);
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  /// Load the cached dataset from disk if present. Idempotent — subsequent
  /// calls return the already-loaded set. Called lazily on first lookup
  /// and eagerly at app startup so the UI knows whether the dataset is
  /// ready before the user opens settings.
  Future<bool> loadFromCacheIfPresent() async {
    if (_zones != null) return true;
    if (_loadAttempted) return false;
    _loadAttempted = true;
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return false;
      final raw = await file.readAsString();
      _parse(raw);
      LogService.instance
          .log('TZ', 'Loaded ${_zones?.length ?? 0} zones from cache');
      _notifyListeners();
      return _zones != null;
    } catch (e) {
      LogService.instance
          .log('TZ', 'Failed to load tz cache: $e', level: LogLevel.error);
      return false;
    }
  }

  /// Download and persist a fresh dataset from the configured URL.
  /// Returns true on success. The download is allowed to be slow and
  /// large (tens of megabytes); callers should show progress UI.
  Future<bool> download({Duration timeout = const Duration(minutes: 5)}) async {
    final url = await getUrl();
    try {
      LogService.instance.log('TZ', 'Downloading $url');
      final response = await http.get(
        Uri.parse(url),
        headers: const {'User-Agent': 'Webspace (+https://github.com/theoden8/webspace_app)'},
      ).timeout(timeout);
      if (response.statusCode != 200) {
        LogService.instance.log(
            'TZ', 'Download failed: HTTP ${response.statusCode}',
            level: LogLevel.error);
        return false;
      }

      String body;
      if (url.toLowerCase().endsWith('.zip')) {
        // timezone-boundary-builder release zips name the inner file
        // `combined-now.json` (or `combined.json`, `combined-with-oceans.json`)
        // — not `.geojson` — even though the *zip* is `*.geojson.zip`.
        // Accept either extension; fall back to the largest JSON-ish file
        // if neither is present so the dataset doesn't fail to load when a
        // future release renames things.
        final archive = ZipDecoder().decodeBytes(response.bodyBytes);
        ArchiveFile? gj;
        ArchiveFile? largestJson;
        var largestSize = 0;
        for (final f in archive.files) {
          if (!f.isFile) continue;
          final n = f.name.toLowerCase();
          if (n.endsWith('.geojson')) {
            gj = f;
            break;
          }
          if (n.endsWith('.json') && f.size > largestSize) {
            largestJson = f;
            largestSize = f.size;
          }
        }
        gj ??= largestJson;
        if (gj == null) {
          LogService.instance.log('TZ',
              'Zip contains no .geojson or .json file (entries: '
              '${archive.files.where((f) => f.isFile).map((f) => f.name).join(", ")})',
              level: LogLevel.error);
          return false;
        }
        body = utf8.decode(gj.content as List<int>);
      } else {
        body = response.body;
      }

      // Write through to disk first so a parse failure leaves the file
      // recoverable (the user can edit it / re-download).
      final file = await _cacheFile();
      await file.writeAsString(body);

      _parse(body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _lastUpdatedPrefKey, DateTime.now().toIso8601String());
      LogService.instance.log('TZ',
          'Downloaded and parsed ${_zones?.length ?? 0} zones from $url');
      _notifyListeners();
      return true;
    } catch (e) {
      LogService.instance
          .log('TZ', 'Download error: $e', level: LogLevel.error);
      return false;
    }
  }

  /// Drop the cached dataset and any in-memory parse.
  Future<void> clear() async {
    _zones = null;
    _loadAttempted = false;
    try {
      final file = await _cacheFile();
      if (await file.exists()) await file.delete();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastUpdatedPrefKey);
    } catch (e) {
      LogService.instance
          .log('TZ', 'Clear error: $e', level: LogLevel.error);
    }
    _notifyListeners();
  }

  void _parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final features = (json['features'] as List?) ?? const [];
    final zones = <_ZoneEntry>[];
    for (final f in features) {
      if (f is! Map) continue;
      final props = f['properties'] as Map?;
      final tzid = props?['tzid'] as String?;
      if (tzid == null || tzid.isEmpty) continue;
      final geometry = f['geometry'] as Map?;
      if (geometry == null) continue;
      final type = geometry['type'] as String?;
      final coords = geometry['coordinates'] as List?;
      if (coords == null) continue;

      final polygons = <List<Float64List>>[];
      double minLng = double.infinity,
          minLat = double.infinity,
          maxLng = -double.infinity,
          maxLat = -double.infinity;

      void addPolygon(List<dynamic> rings) {
        final ringList = <Float64List>[];
        for (final ring in rings) {
          if (ring is! List) continue;
          final flat = Float64List(ring.length * 2);
          var i = 0;
          for (final pt in ring) {
            if (pt is! List || pt.length < 2) continue;
            final lng = (pt[0] as num).toDouble();
            final lat = (pt[1] as num).toDouble();
            flat[i++] = lng;
            flat[i++] = lat;
            if (lng < minLng) minLng = lng;
            if (lat < minLat) minLat = lat;
            if (lng > maxLng) maxLng = lng;
            if (lat > maxLat) maxLat = lat;
          }
          ringList.add(flat);
        }
        if (ringList.isNotEmpty) polygons.add(ringList);
      }

      if (type == 'Polygon') {
        addPolygon(coords);
      } else if (type == 'MultiPolygon') {
        for (final poly in coords) {
          if (poly is List) addPolygon(poly);
        }
      } else {
        continue;
      }

      if (polygons.isEmpty) continue;
      zones.add(_ZoneEntry(tzid, polygons, minLng, minLat, maxLng, maxLat));
    }
    _zones = zones;
  }

  /// Look up the IANA timezone whose polygon set contains the point.
  /// Returns null if the dataset is not ready or the point falls outside
  /// every loaded zone (e.g. open ocean in the no-oceans dataset).
  ///
  /// Uses bbox prefilter + ray-cast PiP. Not blazing fast on the first
  /// matching zone scan, but the result is stable and we only call this
  /// once per webview creation per site, not on every JS call.
  String? lookup(double latitude, double longitude) {
    final zones = _zones;
    if (zones == null || zones.isEmpty) return null;
    for (final z in zones) {
      if (longitude < z.minLng || longitude > z.maxLng) continue;
      if (latitude < z.minLat || latitude > z.maxLat) continue;
      for (final rings in z.polygons) {
        if (rings.isEmpty) continue;
        // Outer ring contains the point AND no hole contains it.
        if (!_pointInRing(rings.first, longitude, latitude)) continue;
        var inHole = false;
        for (var i = 1; i < rings.length; i++) {
          if (_pointInRing(rings[i], longitude, latitude)) {
            inHole = true;
            break;
          }
        }
        if (!inHole) return z.tzid;
      }
    }
    return null;
  }

  /// Even-odd ray-cast test. `ring` is a flat [lng, lat, lng, lat, ...]
  /// closed polygon. Robust enough for IANA zone polygons; we don't
  /// special-case the antimeridian because the dataset already splits
  /// zones that cross it.
  static bool _pointInRing(Float64List ring, double x, double y) {
    var inside = false;
    final n = ring.length;
    if (n < 6) return false;
    for (var i = 0, j = n - 2; i < n; j = i, i += 2) {
      final xi = ring[i], yi = ring[i + 1];
      final xj = ring[j], yj = ring[j + 1];
      final intersects = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 1e-30 : (yj - yi)) + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }
}
