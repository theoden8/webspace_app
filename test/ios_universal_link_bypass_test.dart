import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';

void main() {
  group('IosUniversalLinkBypass.shouldCancelAndReissue', () {
    test('first pass returns true (caller cancels + reissues)', () {
      final bypass = IosUniversalLinkBypass();
      expect(bypass.shouldCancelAndReissue('https://maps.google.com/maps'),
          isTrue);
    });

    test('second pass within memo window returns false (caller allows) (IOS-UL-003)', () {
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
    test('user tap on http link is eligible (IOS-UL-001)', () {
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          currentUrl: 'https://example.com/start',
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
          currentUrl: 'https://example.com/start',
          isLinkActivated: false,
          isFormSubmitted: true,
          httpMethod: 'POST',
        ),
        isFalse,
      );
    });

    test('GET redirect following a form POST IS eligible', () {
      // The user-reported Google Maps case: tapping "accept cookies" on
      // consent.google.com POSTs to /save, which 302s to maps.google.com.
      // WKWebView tags that redirect hop .formSubmitted, but it is
      // re-fetched as a bodyless GET. Reissuing a GET via loadUrl is
      // lossless and is what keeps the native Maps app from launching.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          currentUrl: 'https://example.com/start',
          isLinkActivated: false,
          isFormSubmitted: true,
          httpMethod: 'GET',
        ),
        isTrue,
      );
    });

    test('GET-method form submit (search box) IS eligible', () {
      // A GET form (e.g. a search box) has its params in the query
      // string, no body to drop, so reissuing via loadUrl is safe.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps?q=cafe',
          currentUrl: 'https://example.com/start',
          isLinkActivated: false,
          isFormSubmitted: true,
          httpMethod: 'get',
        ),
        isTrue,
      );
    });

    test('form submit with unknown method is NOT eligible', () {
      // Conservative default: if the platform doesn't report a method,
      // we can't rule out a POST body, so pass through unchanged.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          currentUrl: 'https://example.com/start',
          isLinkActivated: false,
          isFormSubmitted: true,
          httpMethod: null,
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
          currentUrl: 'https://example.com/start',
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
          currentUrl: 'https://example.com/start',
          isLinkActivated: true,
        ),
        isFalse,
      );
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'about:blank',
          currentUrl: 'https://example.com/start',
          isLinkActivated: true,
        ),
        isFalse,
      );
    });

    group('fragment navigation within the current document (IOS-UL-007)', () {
      const pr = 'https://github.com/WebKit/WebKit/pull/65415';
      bool eligible(String url, {required String? currentUrl}) =>
          IosUniversalLinkBypass.isEligibleNavigation(
            isMainFrame: true,
            url: url,
            currentUrl: currentUrl,
            isLinkActivated: true,
          );

      test('opening a notification from the inbox is reissued once', () {
        expect(
          eligible('$pr?notification_referrer_id=NT_x#issuecomment-1',
              currentUrl: 'https://github.com/notifications'),
          isTrue,
        );
      });

      test('GitHub moving to its own anchor after load is NOT reissued', () {
        // The reload loop: GitHub drops notification_referrer_id with
        // replaceState, then navigates to the anchor it is already on after
        // every load. Reissued, that is a full load, which navigates again.
        expect(eligible('$pr#issuecomment-1', currentUrl: '$pr#issuecomment-1'),
            isFalse);
      });

      test('a hash added to the current page is NOT reissued', () {
        expect(eligible('$pr#issuecomment-1', currentUrl: pr), isFalse);
        expect(eligible('$pr#issuecomment-2', currentUrl: '$pr#issuecomment-1'),
            isFalse);
      });

      test('an empty fragment still stays in the document', () {
        expect(eligible('$pr#', currentUrl: pr), isFalse);
      });

      test('the same path with another query loads a new document', () {
        expect(eligible('$pr#issuecomment-1', currentUrl: '$pr?tab=files'),
            isTrue);
      });

      test('dropping the fragment loads a new document', () {
        // HTML navigates to a fragment only when the target has one.
        expect(eligible(pr, currentUrl: '$pr#issuecomment-1'), isTrue);
      });

      test('an unknown current page leaves the tap eligible', () {
        expect(eligible('$pr#issuecomment-1', currentUrl: null), isTrue);
      });
    });

    test('programmatic navigation (no link activation) is NOT eligible (IOS-UL-002)', () {
      // Initial loads, server redirects without a tap origin, and
      // pushState SPA navs all surface as `.other` — they don't
      // activate AASA on iOS and don't need the bypass.
      expect(
        IosUniversalLinkBypass.isEligibleNavigation(
          isMainFrame: true,
          url: 'https://maps.google.com/maps',
          currentUrl: 'https://example.com/start',
          isLinkActivated: false,
        ),
        isFalse,
      );
    });
  });
}
