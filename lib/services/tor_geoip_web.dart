import 'package:webspace/services/tor_geoip.dart';

/// No Tor runtime on web, so nothing to keep a table for.
TorGeoIpStore? createTorGeoIpStore() => null;
