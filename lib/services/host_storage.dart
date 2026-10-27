// The app's cache and data directories and the services built on them.
//
// Kept apart from host_platform because path_provider pulls in Flutter:
// host_platform has to stay importable from plain Dart, and this half does
// not.
export 'host_storage_web.dart' if (dart.library.io) 'host_storage_io.dart';
