import 'package:webspace/services/external_tor_runtime.dart';
import 'package:webspace/services/tor_engine.dart';

/// No Tor runtime on web, so no listener to ask.
TorSocksProbe? createTorSocksProbe() => null;

ExternalTorIdentify? createExternalTorIdentify() => null;
