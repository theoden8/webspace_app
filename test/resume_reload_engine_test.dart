import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/resume_reload_engine.dart';

/// Drive a full failed navigation: start, error, load-stop (the error page).
/// Mirrors the platform callback order — `onReceivedError` precedes
/// `onLoadStop` for the same navigation.
void _failNavigation(ResumeReloadEngine e, String url, String errorType) {
  e.noteLoad(MainFrameLoadSignal.started(url));
  e.noteLoad(MainFrameLoadSignal.failed(url, errorType));
  e.noteLoad(const MainFrameLoadSignal.settled());
}

void _completeNavigation(ResumeReloadEngine e, String url) {
  e.noteLoad(MainFrameLoadSignal.started(url));
  e.noteLoad(const MainFrameLoadSignal.settled());
}

void main() {
  group('error classification (PAUSE-022)', () {
    test('connectivity failures are retryable', () {
      for (final type in [
        'HOST_LOOKUP',
        'CANNOT_CONNECT_TO_HOST',
        'IO',
        'TIMEOUT',
        'NOT_CONNECTED_TO_INTERNET',
        'NETWORK_CONNECTION_LOST',
        'UNKNOWN',
      ]) {
        expect(ResumeReloadEngine.isRetryable(type), isTrue, reason: type);
      }
    });

    test('failures a retry cannot or must not fix are not retryable', () {
      for (final type in [
        'BAD_URL',
        'FILE_NOT_FOUND',
        'UNSUPPORTED_SCHEME',
        'TOO_MANY_REDIRECTS',
        'TOO_MANY_REQUESTS',
        'UNSAFE_RESOURCE',
        'FAILED_SSL_HANDSHAKE',
        'SERVER_CERTIFICATE_UNTRUSTED',
        'SECURE_CONNECTION_FAILED',
        'USER_AUTHENTICATION_FAILED',
      ]) {
        expect(ResumeReloadEngine.isRetryable(type), isFalse, reason: type);
      }
    });
  });

  group('failed load is re-issued on resume', () {
    test('a network failure plans a retry of the failed URL', () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
      e.noteAppBackgrounded();

      final plan = e.planRetry();
      expect(plan.action, ResumeRetryAction.retryNow);
      expect(plan.url, 'https://example.com/');
    });

    test('a non-retryable failure plans nothing', () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'BAD_URL');
      e.noteAppBackgrounded();

      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('a page that loaded fine plans nothing', () {
      final e = ResumeReloadEngine();
      _completeNavigation(e, 'https://example.com/');
      e.noteAppBackgrounded();

      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('issuing the retry clears the trigger so it cannot re-fire', () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'TIMEOUT');
      e.noteRetryIssued();

      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('a retry that fails again is retried once more, then the budget stops it',
        () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');

      expect(e.planRetry().action, ResumeRetryAction.retryNow);
      e.noteRetryIssued();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');

      expect(e.planRetry().action, ResumeRetryAction.retryNow);
      e.noteRetryIssued();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');

      expect(e.attempts, ResumeReloadEngine.maxAttempts);
      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('a successful load refills the budget', () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
      e.noteRetryIssued();
      e.noteRetryIssued();
      expect(e.planRetry().action, ResumeRetryAction.none);

      _completeNavigation(e, 'https://example.com/');
      expect(e.attempts, 0);
    });

    test('returning to the app refills the budget — connectivity may be fixed',
        () {
      final e = ResumeReloadEngine();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
      e.noteRetryIssued();
      e.noteRetryIssued();
      expect(e.planRetry().action, ResumeRetryAction.none);

      e.noteAppBackgrounded();
      _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
      expect(e.planRetry().action, ResumeRetryAction.retryNow);
    });
  });

  group('load still in flight at background time', () {
    test('a load stranded mid-flight waits out the grace before being re-issued',
        () {
      final e = ResumeReloadEngine();
      e.noteLoad(MainFrameLoadSignal.started('https://example.com/'));
      e.noteAppBackgrounded();

      final first = e.planRetry();
      expect(first.action, ResumeRetryAction.waitAndReplan);
      expect(first.delay, ResumeReloadEngine.stallGrace);

      e.noteStallGraceElapsed();
      final second = e.planRetry();
      expect(second.action, ResumeRetryAction.retryNow);
      expect(second.url, 'https://example.com/');
    });

    test('a merely slow load that finishes during the grace is left alone', () {
      final e = ResumeReloadEngine();
      e.noteLoad(MainFrameLoadSignal.started('https://example.com/'));
      e.noteAppBackgrounded();
      expect(e.planRetry().action, ResumeRetryAction.waitAndReplan);

      e.noteLoad(const MainFrameLoadSignal.settled());
      e.noteStallGraceElapsed();
      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('a load started after the resume is not treated as stranded', () {
      final e = ResumeReloadEngine();
      _completeNavigation(e, 'https://example.com/');
      e.noteAppBackgrounded();
      e.noteLoad(MainFrameLoadSignal.started('https://example.com/next'));

      expect(e.planRetry().action, ResumeRetryAction.none);
    });

    test('a stranded load that errors during the grace retries the failed URL',
        () {
      final e = ResumeReloadEngine();
      e.noteLoad(MainFrameLoadSignal.started('https://example.com/'));
      e.noteAppBackgrounded();
      expect(e.planRetry().action, ResumeRetryAction.waitAndReplan);

      e.noteLoad(
          MainFrameLoadSignal.failed('https://example.com/', 'HOST_LOOKUP'));
      e.noteLoad(const MainFrameLoadSignal.settled());
      final plan = e.planRetry();
      expect(plan.action, ResumeRetryAction.retryNow);
      expect(plan.url, 'https://example.com/');
    });
  });

  test('a fresh navigation supersedes a pending failure', () {
    final e = ResumeReloadEngine();
    _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
    e.noteLoad(MainFrameLoadSignal.started('https://elsewhere.example/'));

    expect(e.failedUrl, isNull);
    expect(e.planRetry().action, ResumeRetryAction.none);
  });

  test('reset drops all recovery state', () {
    final e = ResumeReloadEngine();
    _failNavigation(e, 'https://example.com/', 'HOST_LOOKUP');
    e.reset();

    expect(e.failedUrl, isNull);
    expect(e.attempts, 0);
    expect(e.planRetry().action, ResumeRetryAction.none);
  });
}
