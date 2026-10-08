// The documents directory and the services built on it.
//
// Kept apart from host_platform because path_provider pulls in Flutter:
// host_platform has to stay importable from plain Dart (tool/dump_shim_js.dart
// reaches it through the shim builders), and this half does not.
export 'host_storage_web.dart' if (dart.library.io) 'host_storage_io.dart';
