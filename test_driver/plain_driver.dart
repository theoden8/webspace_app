// Driver for arms that assert nothing on the host side.
//
// `test_driver/integration_test.dart` exists for the screenshot tier: it
// connects a `FlutterDriver` and runs a native screenshot watcher. The proxy
// arms report through their own fixtures and want none of that.
//
// It exists at all so the macOS tier can use `flutter drive --no-build`.
// `flutter test -d macos` rebuilds the app on every invocation and has no
// flag to skip it -- 38 builds and about 29 of the step's 60 minutes in run
// 35659213308 -- while each arm still needs its own app process, because the
// proxy slot is per process (BUG-014 gap -2).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
