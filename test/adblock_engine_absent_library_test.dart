import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';

/// `AdblockEngine`'s entry points all document "returns null when the library
/// can't be loaded on this platform/arch". On Apple that contract was broken:
/// `DynamicLibrary.process()` always succeeds (it is a handle on the running
/// process, not a file), so a build without the framework linked got a handle
/// and threw `ArgumentError` from the first `lookup` instead of returning
/// null. `ContentBlockerService.rustEngineSupportedOnPlatform` is called from
/// `AppSettingsScreen.build()`, so the throw took the settings screen down —
/// found by the first widget test to build that screen on a macOS runner.
///
/// On a host with the library present these assertions pass trivially; the
/// point is the *absent* case, which is every `flutter test` process on macOS
/// and Linux CI.
void main() {
  test('load returns null rather than throwing when no library is linked', () {
    expect(() => AdblockEngine.load(''), returnsNormally);
  });

  test('loadFromSerialized returns null rather than throwing', () {
    expect(() => AdblockEngine.loadFromSerialized(Uint8List.fromList(const [1, 2, 3])),
        returnsNormally);
  });

  test('depLicenses returns a list rather than throwing', () {
    expect(AdblockEngine.depLicenses, returnsNormally);
  });

  test('the settings screen probe never throws (crashed AppSettingsScreen)',
      () {
    expect(() => ContentBlockerService.instance.rustEngineSupportedOnPlatform,
        returnsNormally);
  });
}
