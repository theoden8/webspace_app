// Entry point for the adblock engine. Native builds get the dart:ffi binding
// to Brave's adblock-rust; the web target (design gallery only) gets a half
// that cannot construct an engine. See adblock_engine_web.dart for why that is
// the safe shape.

export 'adblock_engine_web.dart' if (dart.library.io) 'adblock_engine_io.dart';
