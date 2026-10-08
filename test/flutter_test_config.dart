import 'dart:async';
import 'dart:io';

import 'package:webspace/services/page_js.dart';

/// Every test sees the page scripts the app loads at startup, read from the
/// checkout rather than the asset bundle so a test needs no Flutter binding.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await PageJs.load(read: (path) => File(path).readAsString());
  await testMain();
}
