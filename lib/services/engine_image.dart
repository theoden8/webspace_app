/// What a dart:ui decode or raster throws when the engine refuses the bytes
/// or the picture: undecodable data, a zero-sized target, a failed render.
final class EngineImageFailure implements Exception {
  const EngineImageFailure(this.message);

  /// The engine's report, as its exception printed it.
  final String message;

  @override
  String toString() => 'EngineImageFailure: $message';
}

/// Runs [call], one dart:ui image decode or raster, with what the engine
/// throws named once: it reports every refusal as a plain [Exception].
Future<T> engineImage<T>(Future<T> Function() call) async {
  try {
    return await call();
    // ignore: webspace_lints/catch_all
  } on Exception catch (e, stack) {
    // sky_engine/lib/ui/painting.dart:2416-2427, 8531, 9213-9251.
    Error.throwWithStackTrace(EngineImageFailure('$e'), stack);
  }
}
