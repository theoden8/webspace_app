import 'package:meta/meta.dart';
import 'package:webspace/platform/host_platform.dart';

/// Where this build was installed from, which decides what App Review's
/// rules let it offer (WEBEXT-019).
enum AppDistribution {
  /// The App Store: every iOS build, and a macOS build carrying the Mac App
  /// Store's receipt.
  appStore,

  /// Anywhere else: a macOS build signed for direct download, a developer's
  /// build, and every other platform.
  direct,
}

/// This build's [AppDistribution].
AppDistribution get hostDistribution =>
    debugHostDistribution ??
    (hostIsIOS || (hostIsMacOS && hostHasAppStoreReceipt())
        ? AppDistribution.appStore
        : AppDistribution.direct);

@visibleForTesting
AppDistribution? debugHostDistribution;
