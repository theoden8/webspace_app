/// Argument the Android notification worker passes to `main` when it starts
/// an engine of its own for a background wake (NOTIF-016).
const String kBackgroundWakeArg = '--background-wake';

/// This process's Dart was started by the notification worker, with no
/// activity, for one background wake. Nothing in it is ever on screen, and
/// Android's native blockers find a site's webview only through the
/// activity's view tree or by a headless webview's id, so it builds no site
/// webview: the wake checks every notification site headless instead.
bool launchedForBackgroundWake = false;
