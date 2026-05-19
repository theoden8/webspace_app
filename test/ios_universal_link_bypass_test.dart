import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';

void main() {
  group('IosUniversalLinkBypass.shouldCancelAndReissue', () {
    test('first pass returns true (caller cancels + reissues)', () {
      final bypass = IosUniversalLinkBypass();
      expect(bypass.shouldCancelAndReissue('https://maps.google.com/maps'),
          isTrue);
    });

    test('second pass within memo window returns false (caller allows)', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      // Reissued nav arrives 50ms later — must be allowed through.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isFalse);
    });

    test('third pass after second pass triggers bypass again', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      // Second pass consumes the memo entry.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isFalse);
      // A real new navigation later (e.g. user re-enters the URL) is
      // bypassed again, not allowed silently.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(seconds: 30))), isTrue);
    });

    test('memo expires after the window even without a second pass', () {
      // If the reissued nav never arrives (e.g. user navigates away
      // mid-flight), the memo entry shouldn't pin the URL forever — a
      // future navigation 5s later still triggers bypass.
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(seconds: 5))), isTrue);
    });

    test('different URLs are tracked independently', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/A', now: t), isTrue);
      expect(bypass.shouldCancelAndReissue(
          'https://www.google.com/maps',
          now: t.add(const Duration(milliseconds: 100))), isTrue);
      // Each URL's reissue arrives separately.
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/place/A',
          now: t.add(const Duration(milliseconds: 200))), isFalse);
      expect(bypass.shouldCancelAndReissue(
          'https://www.google.com/maps',
          now: t.add(const Duration(milliseconds: 300))), isFalse);
    });

    test('treats every URL as eligible — no domain filtering', () {
      // Generic bypass: the class doesn't decide which URLs are
      // AASA-matching. The webview-side gate (Platform.isIOS,
      // main frame, http(s), hasGesture) does that filtering. Here
      // we just confirm the memo doesn't accidentally exempt some
      // URLs by host.
      final bypass = IosUniversalLinkBypass();
      expect(bypass.shouldCancelAndReissue('https://example.com/'), isTrue);
      expect(bypass.shouldCancelAndReissue('https://github.com/foo'), isTrue);
      expect(bypass.shouldCancelAndReissue('http://insecure.example/'), isTrue);
    });

    test('clear() resets the memo', () {
      final bypass = IosUniversalLinkBypass();
      final t = DateTime(2026, 1, 1, 12, 0, 0);
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps', now: t), isTrue);
      bypass.clear();
      // After clear, the next call to the same URL bypasses again
      // (memo no longer says "you just reissued me").
      expect(bypass.shouldCancelAndReissue(
          'https://maps.google.com/maps',
          now: t.add(const Duration(milliseconds: 50))), isTrue);
    });
  });

  group('IosUniversalLinkBypass.isEligibleNavigation', () {
    test('user tap on http link is eligible', () {
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          isLinkActivated: true,
        ),
        isTrue,
      );
    });

    test('form POST is NOT eligible (loadUrl would drop the body)', () {
      // Regression: LinkedIn's `/checkpoint/lg/login-submit` 404'd because
      // the bypass cancelled the POST and reissued it as a GET. Form
      // POSTs to AASA-matching endpoints are vanishingly rare; breaking
      // every login form to catch them is not the right trade.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://www.linkedin.com/checkpoint/lg/login-submit?_l=de_DE',
          isLinkActivated: false,
        ),
        isFalse,
      );
    });

    test('subframe navigation is NOT eligible', () {
      // AASA only matches on top-level navigations; iframes never
      // route to the native app.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: false,
          url: 'https://maps.google.com/maps',
          isLinkActivated: true,
        ),
        isFalse,
      );
    });

    test('non-http(s) scheme is NOT eligible', () {
      // intent://, tel:, mailto: etc. are handled by ExternalUrlParser.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'intent://maps.google.com#Intent;...;end',
          isLinkActivated: true,
        ),
        isFalse,
      );
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'about:blank',
          isLinkActivated: true,
        ),
        isFalse,
      );
    });

    test('programmatic navigation (no link activation) is NOT eligible', () {
      // Initial loads, server redirects without a tap origin, and
      // pushState SPA navs all surface as `.other` — they don't
      // activate AASA on iOS and don't need the bypass.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          isLinkActivated: false,
        ),
        isFalse,
      );
    });
  });
}
