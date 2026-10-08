/// What a reschedule asks the OS for (NOTIF-005).
enum RefreshScheduleAction { keep, schedule, cancel }

/// One refresh request stays in place while any site has notifications on.
/// It is submitted or cancelled when that answer changes, and submitted again
/// as the app leaves the screen: the iOS request's earliest start counts from
/// its submission, so the one made then keeps a wake off the pages the user
/// has just seen. A site switch, an unload or a resume changes nothing.
class RefreshScheduleEngine {
  static RefreshScheduleAction next({
    required bool? scheduled,
    required bool anyEnabled,
    required bool leavingScreen,
  }) {
    if (scheduled != anyEnabled) {
      return anyEnabled
          ? RefreshScheduleAction.schedule
          : RefreshScheduleAction.cancel;
    }
    if (leavingScreen && anyEnabled) return RefreshScheduleAction.schedule;
    return RefreshScheduleAction.keep;
  }
}
