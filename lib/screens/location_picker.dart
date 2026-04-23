import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'package:webspace/settings/location.dart';

/// Full-screen picker for [LocationPickerResult] (lat/lng + accuracy).
///
/// Privacy-first design — there is NO embedded map. Typing or choosing a
/// preset city makes zero network requests. If the user needs to visually
/// pick a coordinate they can tap "Open in OpenStreetMap" which hands off
/// to the platform browser via `url_launcher`, and they paste the result
/// back in. Keeping the map out-of-process means the webspace app itself
/// never calls a tile server and never leaks the user's IP or inspection
/// target to OSM from inside our webview/network stack.
///
/// The tile URL in the "Open in…" button is derived from the `osmTileUrl`
/// global pref so self-hosters can point it at their own provider.
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

/// Popular cities for one-tap selection. Intentionally short — the point is
/// quick access to recognizable anchors, not a gazetteer.
const List<_PresetCity> _presetCities = [
  _PresetCity('Tokyo', 35.6762, 139.6503),
  _PresetCity('London', 51.5074, -0.1278),
  _PresetCity('New York', 40.7128, -74.0060),
  _PresetCity('Paris', 48.8566, 2.3522),
  _PresetCity('Berlin', 52.5200, 13.4050),
  _PresetCity('Los Angeles', 34.0522, -118.2437),
  _PresetCity('Sydney', -33.8688, 151.2093),
  _PresetCity('São Paulo', -23.5505, -46.6333),
  _PresetCity('Moscow', 55.7558, 37.6173),
  _PresetCity('Dubai', 25.2048, 55.2708),
  _PresetCity('Singapore', 1.3521, 103.8198),
  _PresetCity('Hong Kong', 22.3193, 114.1694),
  _PresetCity('Seoul', 37.5665, 126.9780),
  _PresetCity('Mumbai', 19.0760, 72.8777),
  _PresetCity('Mexico City', 19.4326, -99.1332),
  _PresetCity('Cairo', 30.0444, 31.2357),
  _PresetCity('Istanbul', 41.0082, 28.9784),
  _PresetCity('Toronto', 43.6532, -79.3832),
  _PresetCity('Amsterdam', 52.3676, 4.9041),
  _PresetCity('Reykjavík', 64.1466, -21.9426),
];

class _PresetCity {
  final String name;
  final double lat;
  final double lng;
  const _PresetCity(this.name, this.lat, this.lng);
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  late TextEditingController _latController;
  late TextEditingController _lngController;
  late TextEditingController _accController;
  String _tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

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

  bool _coordsValid() {
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat == null || lng == null) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  void _applyPreset(_PresetCity city) {
    setState(() {
      _latController.text = city.lat.toString();
      _lngController.text = city.lng.toString();
    });
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

  Future<void> _openExternalMap() async {
    // Seed the external map at the currently typed coords if valid,
    // otherwise at the world view.
    final lat = double.tryParse(_latController.text.trim()) ?? 0.0;
    final lng = double.tryParse(_lngController.text.trim()) ?? 0.0;
    final zoom = _coordsValid() ? 10 : 2;
    final url = Uri.parse(
      'https://www.openstreetmap.org/?mlat=$lat&mlon=$lng#map=$zoom/$lat/$lng',
    );
    await launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick location'),
        actions: [
          TextButton(
            onPressed: () {
              if (!_coordsValid()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter valid coordinates first')),
                );
                return;
              }
              final acc = double.tryParse(_accController.text.trim()) ?? 50.0;
              Navigator.pop(
                context,
                LocationPickerResult(
                  latitude: double.parse(_latController.text.trim()),
                  longitude: double.parse(_lngController.text.trim()),
                  accuracy: acc > 0 ? acc : 50.0,
                ),
              );
            },
            child: const Text('Done'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
                  onChanged: (_) => setState(() {}),
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
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _accController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Accuracy (meters)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 24),
          Text('Preset cities',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presetCities
                .map((c) => ActionChip(
                      label: Text(c.name),
                      onPressed: () => _applyPreset(c),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          Text('Pick visually',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Text(
            'Opens ${_hostOfTileUrl()} in your device browser — no requests '
            'are made from inside WebSpace. Copy coordinates back into the '
            'fields above when you have a spot.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open in OpenStreetMap'),
            onPressed: _openExternalMap,
          ),
        ],
      ),
    );
  }
}
