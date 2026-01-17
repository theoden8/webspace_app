import 'package:integration_test/integration_test_driver.dart';

/// Test driver for integration tests
/// 
/// This enables screenshot capture and test orchestration when using
/// `flutter drive` command.
/// 
/// Usage:
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/screenshot_test.dart
Future<void> main() => integrationDriver();
