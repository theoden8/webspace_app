import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
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
  final MapController _mapController = MapController();

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
    if (!mounted) return;
    setState(() => _tileUrl = url);
  }

  @override
  void dispose() {
    _latController.dispose();
    _lngController.dispose();
    _accController.dispose();
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
              maxZoom: 19,
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
        Positioned(
          bottom: 4,
          right: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: Colors.white.withValues(alpha: 0.75),
            child: GestureDetector(
              onTap: () =>
                  launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
              child: const Text(
                '© OpenStreetMap contributors',
                style: TextStyle(fontSize: 10, color: Colors.black87),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
