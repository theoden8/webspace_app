import 'package:webspace/services/tor_engine.dart';

/// No Tor runtime on web, so no listener to ask.
TorSocksProbe? createTorSocksProbe() => null;
