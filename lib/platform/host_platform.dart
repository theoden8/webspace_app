/// Host-platform checks that survive a web compile.
///
/// `dart:io`'s `Platform` is unavailable on web, and any file importing it
/// keeps the whole import closure off the web target — which is what kept the
/// app's screens out of the design gallery. Off web these delegate straight to
/// `Platform`, so behaviour (including under `flutter test`, where
/// `defaultTargetPlatform` would have answered differently) is unchanged.
export 'host_platform_web.dart' if (dart.library.io) 'host_platform_io.dart';
