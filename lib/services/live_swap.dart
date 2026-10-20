/// Swapping a page loaded from the engine's cache for the live page once the
/// network answers. Pure Dart: the webview factory drives
/// [awaitOnlineForLiveSwap].
library;

/// Waits between connectivity probes before a page loaded from cache gives
/// up on the live page. The first probe can land while a per-app firewall
/// that cut the app off in the background (CalyxOS/Datura, Android's own
/// background restrictions) has not let it back out yet; a cached page whose
/// subresources fail fast settles inside that window.
const List<Duration> liveSwapProbeDelays = [
  Duration.zero,
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
];

/// Resolves true once [isOnline] reports the network and [stillWanted] still
/// holds, false when every probe in [liveSwapProbeDelays] found it offline or
/// [stillWanted] stopped holding (the user navigated, so their navigation is
/// the intent).
Future<bool> awaitOnlineForLiveSwap({
  required Future<bool> Function() isOnline,
  required bool Function() stillWanted,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  for (final delay in liveSwapProbeDelays) {
    if (delay > Duration.zero) await wait(delay);
    if (!stillWanted()) return false;
    if (await isOnline()) return stillWanted();
  }
  return false;
}
