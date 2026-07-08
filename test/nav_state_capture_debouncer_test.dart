import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/nav_state_capture_debouncer.dart';

void main() {
  const delay = Duration(seconds: 3);

  test('a navigation burst coalesces into one trailing capture', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      var captures = 0;
      // 8 SPA pseudo-navigations 100ms apart (the LinkedIn storm shape).
      for (var i = 0; i < 8; i++) {
        d.schedule('a', () => captures++);
        async.elapse(const Duration(milliseconds: 100));
      }
      expect(captures, 0, reason: 'window still open during the burst');
      async.elapse(delay);
      expect(captures, 1);
    });
  });

  test('capture fires delay after the LAST navigation, not the first', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      var captures = 0;
      d.schedule('a', () => captures++);
      async.elapse(const Duration(seconds: 2));
      d.schedule('a', () => captures++);
      // 3s since the first schedule but only 1s since the second: a
      // leading-edge throttle would have fired; trailing must not.
      async.elapse(const Duration(seconds: 1));
      expect(captures, 0);
      async.elapse(const Duration(seconds: 2));
      expect(captures, 1);
    });
  });

  test('sites debounce independently', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      final fired = <String>[];
      d.schedule('a', () => fired.add('a'));
      async.elapse(const Duration(seconds: 2));
      // b's navigation must not push back a's already-elapsing window.
      d.schedule('b', () => fired.add('b'));
      async.elapse(const Duration(seconds: 1));
      expect(fired, ['a']);
      async.elapse(const Duration(seconds: 2));
      expect(fired, ['a', 'b']);
    });
  });

  test('a new schedule after firing opens a fresh window', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      var captures = 0;
      d.schedule('a', () => captures++);
      async.elapse(delay);
      expect(captures, 1);
      d.schedule('a', () => captures++);
      async.elapse(delay);
      expect(captures, 2);
    });
  });

  test('cancel drops the pending capture without running it', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      var captures = 0;
      d.schedule('a', () => captures++);
      d.cancel('a');
      async.elapse(delay * 2);
      expect(captures, 0);
    });
  });

  test('dispose cancels every pending capture', () {
    fakeAsync((async) {
      final d = NavStateCaptureDebouncer(delay: delay);
      var captures = 0;
      d.schedule('a', () => captures++);
      d.schedule('b', () => captures++);
      d.dispose();
      async.elapse(delay * 2);
      expect(captures, 0);
    });
  });
}
