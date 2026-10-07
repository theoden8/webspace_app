import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/services/repaint_suppression.dart';
import 'package:webspace/services/surface_repaint_engine.dart';
import 'package:webspace/web_view_model.dart';

class _Screen implements SurfaceHost {
  _Screen(this.clock);

  final Duration Function() clock;
  final rebuilds = <Duration>[];

  @override
  bool mounted = true;

  @override
  void rebuild() => rebuilds.add(clock());
}

void main() {
  (_Screen, SurfaceRepaintController) setUp(FakeAsync async) {
    final screen = _Screen(() => async.elapsed);
    return (
      screen,
      SurfaceRepaintController(screen, repaints: true, traceSuffix: ''),
    );
  }

  tearDown(() => RepaintSuppression.set(const []));

  // The nudge-loop race attempts 2-3 fixed: two nudges fired mid-loop must
  // coalesce onto one loop that terminates at a zero inset.
  test('two nudges 50ms apart run one loop and settle at no inset', () {
    fakeAsync((async) {
      final (screen, surface) = setUp(async);
      surface.nudge('first');
      Future.delayed(const Duration(milliseconds: 50), () => surface.nudge('second'));
      async.elapse(const Duration(seconds: 3));
      final gaps = [
        for (var i = 1; i < screen.rebuilds.length; i++)
          screen.rebuilds[i] - screen.rebuilds[i - 1],
      ];
      expect(gaps, everyElement(const Duration(milliseconds: 100)),
          reason: 'a second loop would tick between the first one\'s frames');
      expect(surface.bottomInset, 0.0);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a load settling inside the commit window repaints, past it does not',
      () {
    fakeAsync((async) {
      final (screen, surface) = setUp(async);
      surface.armCommitLatch();
      async.elapse(SurfaceRepaintEngine.commitWindow - const Duration(seconds: 1));
      surface.loadSettled();
      expect(screen.rebuilds, isNotEmpty,
          reason: 'a slow recommit inside the window still repaints');
      async.elapse(const Duration(seconds: 3));
      screen.rebuilds.clear();
      surface.loadSettled();
      expect(screen.rebuilds, isEmpty,
          reason: 'an unrelated navigation past the window does not');
      surface.dispose();
    });
  });

  test('a watched site repaints on its own events only while on screen', () {
    fakeAsync((async) {
      final (screen, surface) = setUp(async);
      final site = WebViewModel(initUrl: 'https://a.example.com');
      var onScreen = false;
      surface.watch(site, onScreen: () => onScreen);
      site.onControllerReady!();
      site.onReloadIssued!();
      site.onPageCommitVisible!();
      site.onLoadSettled!();
      expect(screen.rebuilds, isEmpty,
          reason: 'a site in the background does not repaint the surface');

      onScreen = true;
      site.onReloadIssued!();
      expect(screen.rebuilds, isNotEmpty, reason: 'a reload nudges at once');
      async.elapse(const Duration(seconds: 3));
      screen.rebuilds.clear();
      site.onLoadSettled!();
      expect(screen.rebuilds, isNotEmpty,
          reason: 'the reload latched its recommit (PAUSE-021)');
      async.elapse(const Duration(seconds: 3));
      surface.dispose();
    });
  });

  test('a metrics change repaints only inside the post-resume window', () {
    fakeAsync((async) {
      final (screen, surface) = setUp(async);
      surface.metricsChanged();
      expect(screen.rebuilds, isEmpty, reason: 'steady state: no nudge');
      surface.openResumeWindow();
      surface.metricsChanged();
      expect(screen.rebuilds, isNotEmpty);
      async.elapse(const Duration(seconds: 4));
      screen.rebuilds.clear();
      surface.metricsChanged();
      expect(screen.rebuilds, isEmpty, reason: 'the window closed');
    });
  });

  test('a suppressed trigger and a surface that needs none never repaint', () {
    fakeAsync((async) {
      final (screen, surface) = setUp(async);
      RepaintSuppression.set(['resume']);
      surface.nudge('resume');
      final quiet = SurfaceRepaintController(screen,
          repaints: false, traceSuffix: '');
      quiet.nudge('activate');
      async.elapse(const Duration(seconds: 1));
      expect(screen.rebuilds, isEmpty);
    });
  });

  test('the manual repaint walks every mechanism, the inset following', () {
    fakeAsync((async) {
      final (_, surface) = setUp(async);
      final seen = [for (final _ in ManualRepaint.values) surface.nextManual()];
      expect(seen, ManualRepaint.values);
      surface.nextManual();
      surface.nextManual();
      surface.nudge('manual');
      expect(surface.bottomInset, 16.0, reason: 'inset16 sticks for the loop');
      async.elapse(const Duration(seconds: 2));
    });
  });
}
