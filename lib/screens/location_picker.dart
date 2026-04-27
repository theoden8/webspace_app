import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/current_location_service.dart';

/// Full-screen picker for [LocationPickerResult] (lat/lng + accuracy).
///
/// Two states:
/// - **Placeholder** (default): manual lat/lng/accuracy text fields plus a
///   "Load map" button. No network requests are made — [flutter_map] is not
///   mounted until the user explicitly opts in. This is the privacy-default
///   for a browser that tries to avoid leaking user intent to third parties.
/// - **Map mounted**: after "Load map" is tapped, the map fetches tiles from
///   the URL configured in the `osmTileUrl` global pref (default OSM). Tap
///   anywhere on the map to move the pin, which in turn updates the text
///   fields. The text fields remain editable and keep the pin in sync.
class LocationPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;
  final double initialAccuracy;

  const LocationPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
    this.initialAccuracy = 50.0,
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class LocationPickerResult {
  final double latitude;
  final double longitude;
  final double accuracy;

  const LocationPickerResult({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late TextEditingController _latController;
  late TextEditingController _lngController;
  late TextEditingController _accController;

  bool _mapLoaded = false;
  bool _fetchingLocation = false;
  String _tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  // Compliant User-Agent per OSM Tile Usage Policy: clearly identifies the
  // app, includes a contact URL, and avoids the library default. Populated
  // before the map can mount (see _loadTileUrl).
  String _tileUserAgent = 'Webspace (+https://github.com/theoden8/webspace_app)';
  final MapController _mapController = MapController();
  // Held at field scope so the recognizers are only allocated once and
  // disposed in [dispose]. Building them inline in [_buildMap] would leak on
  // every rebuild (e.g. when the user types coordinates while the map is up).
  late final TapGestureRecognizer _osmCopyrightRecognizer = TapGestureRecognizer()
    ..onTap = () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'));
  late final TapGestureRecognizer _osmFixmapRecognizer = TapGestureRecognizer()
    ..onTap = () => launchUrl(Uri.parse('https://www.openstreetmap.org/fixthemap'));

  @override
  void initState() {
    super.initState();
    _latController = TextEditingController(
      text: widget.initialLatitude?.toString() ?? '',
    );
    _lngController = TextEditingController(
      text: widget.initialLongitude?.toString() ?? '',
    );
    _accController = TextEditingController(
      text: widget.initialAccuracy.toString(),
    );
    _loadTileUrl();
  }

  Future<void> _loadTileUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('osmTileUrl') ?? _tileUrl;
    String ua = _tileUserAgent;
    try {
      final info = await PackageInfo.fromPlatform();
      final v = info.version;
      ua = 'Webspace/$v (+https://github.com/theoden8/webspace_app)';
    } catch (_) {
      // Keep the static fallback if PackageInfo is unavailable.
    }
    if (!mounted) return;
    setState(() {
      _tileUrl = url;
      _tileUserAgent = ua;
    });
  }

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    _accController.dispose();
    _osmCopyrightRecognizer.dispose();
    _osmFixmapRecognizer.dispose();
    super.dispose();
  }

  LatLng? _currentLatLng() {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return LatLng(lat, lng);
  }

  void _setPin(LatLng p) {
    setState(() {
      _latController.text = p.latitude.toStringAsFixed(6);
      _lngController.text = p.longitude.toStringAsFixed(6);
    });
  }

  void _onCoordTyped(String _) {
    setState(() {});
    if (_mapLoaded) {
      final p = _currentLatLng();
      if (p == null) return;
      try {
        _mapController.move(p, _mapController.camera.zoom);
      } catch (_) {
        // Camera not attached yet — ignore; marker still rebuilds from state.
      }
    }
  }

  Future<void> _useCurrentLocation() async {
    if (_fetchingLocation) return;
    setState(() => _fetchingLocation = true);
    final res = await CurrentLocationService.getCurrentLocation();
    if (!mounted) return;
    setState(() => _fetchingLocation = false);
    switch (res.status) {
      case CurrentLocationStatus.ok:
        final fix = res.fix!;
        setState(() {
          _latController.text = fix.latitude.toStringAsFixed(6);
          _lngController.text = fix.longitude.toStringAsFixed(6);
          if (fix.accuracy > 0) {
            _accController.text = fix.accuracy.toStringAsFixed(1);
          }
        });
        if (_mapLoaded) {
          try {
            _mapController.move(LatLng(fix.latitude, fix.longitude), 14.0);
          } catch (_) {}
        }
        break;
      case CurrentLocationStatus.permissionDenied:
        _showSnack('Location permission was not granted.');
        break;
      case CurrentLocationStatus.permissionDeniedForever:
        _showSnack('Location permission is denied. Enable it in system Settings.');
        break;
      case CurrentLocationStatus.serviceDisabled:
        _showSnack('Location services are disabled on this device.');
        break;
      case CurrentLocationStatus.timeout:
        _showSnack('Could not get a location fix in time. Try again outdoors.');
        break;
      case CurrentLocationStatus.unsupported:
        _showSnack('Current location is not available on this platform.');
        break;
      case CurrentLocationStatus.error:
        _showSnack(res.message ?? 'Failed to get current location.');
        break;
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _hostOfTileUrl() {
    try {
      final clean = _tileUrl
          .replaceAll('{z}', '0')
          .replaceAll('{x}', '0')
          .replaceAll('{y}', '0')
          .replaceAll('{s}', 'a');
      return Uri.parse(clean).host;
    } catch (_) {
      return _tileUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick location'),
        actions: [
          TextButton(
            onPressed: () {
              final p = _currentLatLng();
              if (p == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter valid coordinates first')),
                );
                return;
              }
              final acc = double.tryParse(_accController.text.trim()) ?? 50.0;
              Navigator.pop(
                context,
                LocationPickerResult(
                  latitude: p.latitude,
                  longitude: p.longitude,
                  accuracy: acc > 0 ? acc : 50.0,
                ),
              );
            },
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildCoordinateInputs(),
          Expanded(
            child: _mapLoaded ? _buildMap() : _buildPlaceholder(),
          ),
        ],
      ),
    );
  }

  Widget _buildCoordinateInputs() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _latController,
                  keyboardType: const TextInputType.numberWithOptions(
                      signed: true, decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Latitude',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: _onCoordTyped,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _lngController,
                  keyboardType: const TextInputType.numberWithOptions(
                      signed: true, decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Longitude',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: _onCoordTyped,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _accController,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Accuracy (meters)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (CurrentLocationService.isSupported) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: _fetchingLocation
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
                label: Text(_fetchingLocation
                    ? 'Getting current location…'
                    : 'Use current location'),
                onPressed: _fetchingLocation ? null : _useCurrentLocation,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text(
              'Map is not loaded.',
              style: TextStyle(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Loading the map will fetch tiles from ${_hostOfTileUrl()}, '
              'revealing the area you view to the tile server. '
              'You can also just type coordinates above and tap Done.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.download_outlined),
              label: const Text('Load map'),
              onPressed: () => setState(() => _mapLoaded = true),
            ),
            const SizedBox(height: 8),
            Text(
              'Change provider in App Settings → Location picker',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    final initial = _currentLatLng() ?? const LatLng(0, 0);
    final initialZoom = _currentLatLng() == null ? 2.0 : 10.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initial,
            initialZoom: initialZoom,
            onTap: (_, p) => _setPin(p),
          ),
          children: [
            TileLayer(
              urlTemplate: _tileUrl,
              userAgentPackageName: 'com.webspace.app',
              tileProvider: NetworkTileProvider(
                headers: {'User-Agent': _tileUserAgent},
              ),
              maxZoom: 19,
              // In dark mode, post-process the standard light cartography
              // into a dark-friendly version client-side instead of
              // requiring a separate dark tile server. The matrix below
              // maps each output channel to the negative luminance of
              // the input (0.2126·R + 0.7152·G + 0.0722·B), then offsets
              // by 255 — i.e. light → dark, dark → light, while
              // preserving relative contrast. Roads, labels, and water
              // stay readable; the map gets a flat dark-grey aesthetic
              // that matches Material's dark surfaces.
              tileBuilder: isDark
                  ? (context, tileWidget, tile) {
                      return ColorFiltered(
                        colorFilter: const ColorFilter.matrix(<double>[
                          -0.2126, -0.7152, -0.0722, 0, 255,
                          -0.2126, -0.7152, -0.0722, 0, 255,
                          -0.2126, -0.7152, -0.0722, 0, 255,
                          0, 0, 0, 1, 0,
                        ]),
                        child: tileWidget,
                      );
                    }
                  : null,
            ),
            if (_currentLatLng() != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: _currentLatLng()!,
                    width: 40,
                    height: 40,
                    child: Icon(
                      Icons.location_pin,
                      color: Theme.of(context).colorScheme.error,
                      size: 40,
                    ),
                  ),
                ],
              ),
          ],
        ),
        // Attribution per OSMF Attribution Guidelines (2021-06-25):
        // - The word "OpenStreetMap" itself is the link to /copyright (not
        //   the whole string) and is visually styled as a link.
        // - 12pt is used for legibility; the guidelines reference WCAG.
        // - Always visible while the map is loaded (no auto-collapse).
        // - "Report a map issue" link is recommended by the Tile Usage Policy.
        // - Surface and text colours adapt to dark theme so the overlay
        //   stays legible on the dark-filtered tiles below.
        Positioned(
          bottom: 4,
          right: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.85),
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87),
                children: [
                  const TextSpan(text: '© '),
                  TextSpan(
                    text: 'OpenStreetMap',
                    style: TextStyle(
                      // Wikipedia-style link blue on light, lighter cyan
                      // on dark — both meet WCAG AA on the chosen surface.
                      color: isDark
                          ? const Color(0xFF6CA0DC)
                          : const Color(0xFF0645AD),
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: _osmCopyrightRecognizer,
                  ),
                  const TextSpan(text: ' contributors · '),
                  TextSpan(
                    text: 'Report a map issue',
                    style: TextStyle(
                      color: isDark
                          ? const Color(0xFF6CA0DC)
                          : const Color(0xFF0645AD),
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: _osmFixmapRecognizer,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
