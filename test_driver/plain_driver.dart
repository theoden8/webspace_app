// Driver for arms that assert nothing on the host side.
//
// `test_driver/integration_test.dart` exists for the screenshot tier: it
// connects a `FlutterDriver` and writes each screenshot into SCREENSHOT_DIR.
// The proxy arms report through their own fixtures and want none of that.
//
// It exists at all so the macOS tier can launch one prebuilt app per file
// (`flutter drive --use-application-binary`, scripts/integration_bundle.sh).
// `flutter test -d macos` rebuilds the app on every invocation and has no
// flag to skip it, while each file still needs its own app process.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
