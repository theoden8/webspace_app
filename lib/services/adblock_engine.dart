// Entry point for the adblock engine. Native builds get the dart:ffi binding
// to Brave's adblock-rust; the web target (design gallery only) gets a half
// that cannot construct an engine. See adblock_engine_web.dart for why that is
// the safe shape.

import 'dart:typed_data';

export 'adblock_engine_web.dart' if (dart.library.io) 'adblock_engine_io.dart';

/// What an engine instance answers. Both halves implement it, so the
/// analyzer holds the web half to the native one; the static constructors
/// (`load`, `loadFromSerialized`) and helpers cannot be part of an interface
/// and are still mirrored by hand.
abstract interface class AdblockEngineApi {
  /// Engine library version string, for diagnostics.
  String get version;

  Uint8List? serialize();

  bool shouldBlock(String url, {String sourceUrl, String requestType});

  List<String> hiddenClassIdSelectors(Set<String> classes,
      {required Set<String> ids, Set<String> exceptions});

  String? redirectFor(String url, {String sourceUrl, String requestType});

  String? rewrittenUrl(String url, {String sourceUrl, String requestType});

  String? cspFor(String url, {String sourceUrl, String requestType});

  Map<String, dynamic>? cosmeticResources(String url);

  void dispose();
}
