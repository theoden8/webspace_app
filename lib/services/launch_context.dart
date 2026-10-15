/// Argument the Android notification worker passes to `main` when it starts
/// an engine of its own for a background wake (NOTIF-016).
const String kBackgroundWakeArg = '--background-wake';

/// What started this process. The entry point decides it and hands it to
/// the app, so nothing reads a launch reason the entry point did not give.
enum ProcessLaunch {
  /// The user opened the app, or the OS restored it.
  user,

  /// The notification worker started this Dart with no activity, for one
  /// background wake. Nothing in it is ever on screen, and Android's native
  /// blockers find a site's webview only through the activity's view tree or
  /// by a headless webview's id, so it builds no site webview: the wake
  /// checks every notification site headless instead (NOTIF-016).
  backgroundWake;

  static ProcessLaunch fromArgs(List<String> args) =>
      args.contains(kBackgroundWakeArg) ? backgroundWake : user;
}
