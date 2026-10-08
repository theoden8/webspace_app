import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/refresh_schedule_engine.dart';

/// NOTIF-005: the refresh request changes when "any site has notifications
/// on" does, and is resubmitted as the app leaves the screen. A device log
/// showed a resubmission on every site switch and resume, each one pushing
/// the earliest start out again while the app was in use.
void main() {
  RefreshScheduleAction next({
    required bool? scheduled,
    required bool any,
    bool leaving = false,
  }) => RefreshScheduleEngine.next(
    scheduled: scheduled,
    anyEnabled: any,
    leavingScreen: leaving,
  );

  test('the first decision of a process always reaches the OS', () {
    expect(next(scheduled: null, any: true), RefreshScheduleAction.schedule);
    expect(next(scheduled: null, any: false), RefreshScheduleAction.cancel);
  });

  test('a change of answer schedules or cancels', () {
    expect(next(scheduled: false, any: true), RefreshScheduleAction.schedule);
    expect(next(scheduled: true, any: false), RefreshScheduleAction.cancel);
  });

  test('an unchanged answer in the app touches nothing', () {
    expect(next(scheduled: true, any: true), RefreshScheduleAction.keep);
    expect(next(scheduled: false, any: false), RefreshScheduleAction.keep);
  });

  test('leaving the screen resubmits a live request, and only a live one', () {
    expect(
      next(scheduled: true, any: true, leaving: true),
      RefreshScheduleAction.schedule,
    );
    expect(
      next(scheduled: false, any: false, leaving: true),
      RefreshScheduleAction.keep,
    );
    expect(
      next(scheduled: true, any: false, leaving: true),
      RefreshScheduleAction.cancel,
    );
  });
}
