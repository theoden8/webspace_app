part of 'webspace_page.dart';

/// Test seam: when set, the page state uses this store instead of
/// constructing a [SecureWebViewStateStorage]. Lets integration tests
/// inject an in-memory store that survives a simulated restart (re-run of
/// [main]) without a platform keychain backend.
@visibleForTesting
WebViewStateStorage? debugWebViewStateStorageOverride;

/// Test seam: live reference to the current run's loaded site models, so
/// integration tests can reach a webview controller (URL, back/forward,
/// restore state) the widget tree doesn't otherwise expose.
@visibleForTesting
List<WebViewModel>? debugWebViewModels;

/// Test seam: the cold start of the current run, from the first frame to the
/// last step of [StartupController.restore], so a benchmark can time it.
@visibleForTesting
Future<void>? debugStartupRestore;
