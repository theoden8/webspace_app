import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/shortcut_service.dart';

/// For the rest of the test, a device whose launcher takes no home shortcut
/// (HS-004), as a TV's. Every other test runs where one can be added
/// (`flutter_test_config.dart`).
void withoutShortcuts() {
  final before = ShortcutService.debugOfferedOverride;
  ShortcutService.debugOfferedOverride = false;
  addTearDown(() => ShortcutService.debugOfferedOverride = before);
}
