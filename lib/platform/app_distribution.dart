import 'package:flutter/services.dart' show appFlavor;
import 'package:meta/meta.dart';
import 'package:webspace/platform/host_platform.dart';

/// Where this build is for, which decides what App Review's rules let it
/// offer (WEBEXT-019).
enum AppDistribution {
  /// The App Store: an iOS or macOS build made without [directFlavor].
  appStore,

  /// Anywhere else: an iOS or macOS build made with [directFlavor] (one you
  /// build yourself, CI's unsigned IPA, the Developer ID download), and every
  /// other platform.
  direct,
}

/// The flavor an iOS or macOS build installed outside the App Store is made
/// with (`--flavor direct`): the `direct` scheme and its `-direct`
/// configurations in each Xcode project. A build without it is an App Store
/// build, so a flavor forgotten leaves out what App Review forbids.
const String directFlavor = 'direct';

/// What this build was made for, fixed when it was compiled, so code only a
/// [AppDistribution.direct] build may run is left out of every other.
const AppDistribution builtFor = appFlavor == directFlavor
    ? AppDistribution.direct
    : AppDistribution.appStore;

/// This build's [AppDistribution].
AppDistribution get hostDistribution =>
    debugHostDistribution ??
    (hostIsIOS || hostIsMacOS ? builtFor : AppDistribution.direct);

@visibleForTesting
AppDistribution? debugHostDistribution;
