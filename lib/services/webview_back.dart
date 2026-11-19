import 'package:webspace/services/webview_controller.dart';

/// How long a tried `goBack()` is given to move the URL before the step
/// reads it (NAV-002).
const kBackSettle = Duration(milliseconds: 150);

/// What one back step in a webview's own history did.
enum BackStep {
  /// The page went back.
  moved,

  /// There was nothing to go back to.
  atStart,

  /// The view went away while the step was out.
  abandoned,
}

/// One step back in [view]'s own history, as NAV-002 decides it for every
/// surface that runs one. Where `canGoBack()` is trusted (Android, whose
/// Chromium counts `pushState` entries) it alone says whether there is
/// history; elsewhere (WebKit, whose `canGoBack()` misses them) `goBack()` is
/// tried and the URL read again after [kBackSettle]. [goBack] is the
/// caller's step, which may repaint after it; [live] is asked after every
/// await.
Future<BackStep> stepBack(
  WebViewController view, {
  required bool trustsCanGoBack,
  required Future<void> Function() goBack,
  required bool Function() live,
}) async {
  if (trustsCanGoBack) {
    final can = await view.canGoBack();
    if (!live()) return BackStep.abandoned;
    if (!can) return BackStep.atStart;
    await goBack();
    return BackStep.moved;
  }
  final before = (await view.getUrl())?.toString();
  await goBack();
  await Future<void>.delayed(kBackSettle);
  if (!live()) return BackStep.abandoned;
  final after = (await view.getUrl())?.toString();
  if (!live()) return BackStep.abandoned;
  return before == after ? BackStep.atStart : BackStep.moved;
}
