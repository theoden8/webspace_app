import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/webview.dart';

/// Test harness that simulates shouldOverrideUrlLoading behavior.
/// This tests the domain comparison logic without requiring actual webviews.
class NavigationTestHarness {
  final List<WebViewModel> sites = [];

  /// Records of launchUrl calls: (url, homeTitle)
  final List<({String url, String? homeTitle})> launchUrlCalls = [];

  /// Per-site gesture propagation state (mirrors the local variables
  /// in WebViewModel.getWebView's closure).
  final Map<int, DateTime?> _lastSameDomainGestureTime = {};

  void addSite(String url, {String? name, bool blockAutoRedirects = true}) {
    sites.add(WebViewModel(
      initUrl: url,
      name: name ?? 'Site ${sites.length + 1}',
      blockAutoRedirects: blockAutoRedirects,
    ));
  }

  /// Simulates a navigation request on a specific site's webview.
  /// This replicates the exact logic from WebViewModel.getWebView's
  /// shouldOverrideUrlLoading callback.
  /// Returns true if navigation was allowed, false if blocked (opened nested)
  bool simulateNavigation(int siteIndex, String targetUrl, {bool hasGesture = true}) {
    final site = sites[siteIndex];

    // Allow data: and blob: URIs (inline content, no domain)
    final scheme = Uri.tryParse(targetUrl)?.scheme ?? '';
    if (scheme == 'data' || scheme == 'blob') {
      return true;
    }

    // Replicate the exact logic from WebViewModel.getWebView
    final requestNormalized = getNormalizedDomain(targetUrl);
    final initialNormalized = getNormalizedDomain(site.initUrl);

    if (requestNormalized == initialNormalized) {
      if (hasGesture) {
        _lastSameDomainGestureTime[siteIndex] = DateTime.now();
      }
      return true; // Allow - same logical domain
    }

    // Gesture propagation for cross-domain redirects
    bool effectiveHasGesture = hasGesture;
    final lastGesture = _lastSameDomainGestureTime[siteIndex];
    if (!hasGesture && lastGesture != null) {
      final elapsed = DateTime.now().difference(lastGesture);
      if (elapsed.inSeconds < 10) {
        effectiveHasGesture = true;
      }
      _lastSameDomainGestureTime[siteIndex] = null; // Consume
    }

    if (site.blockAutoRedirects && !effectiveHasGesture) {
      return false; // Cancel - blocked (no nested webview opened)
    }

    // Would block and call launchUrl with site's name as homeTitle
    launchUrlCalls.add((url: targetUrl, homeTitle: site.name));
    return false; // Cancel - open in nested webview
  }

  /// Simulates the onUrlChanged cross-domain redirect detection.
  /// Returns true if a cross-domain redirect was detected and handled.
  bool simulateUrlChanged(int siteIndex, String newUrl) {
    final site = sites[siteIndex];

    // Skip data: and blob: URIs (inline content, no domain)
    final scheme = Uri.tryParse(newUrl)?.scheme ?? '';
    if (scheme == 'data' || scheme == 'blob') {
      return false;
    }

    final urlDomain = getNormalizedDomain(newUrl);
    final initDomain = getNormalizedDomain(site.initUrl);

    if (urlDomain != initDomain && !WebViewFactory.isCaptchaChallenge(newUrl)) {
      launchUrlCalls.add((url: newUrl, homeTitle: site.name));
      return true; // Cross-domain redirect detected
    }
    return false;
  }

  void clearLaunchUrlCalls() {
    launchUrlCalls.clear();
  }
}

void main() {
  group('Nested Webview Navigation - Domain Check per Site', () {
    late NavigationTestHarness harness;

    setUp(() {
      harness = NavigationTestHarness();
    });

    test('each site should use its own initUrl for domain comparison', () {
      // Setup: Site A (GitHub), Site B (GitLab)
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');
      // Sites created - ready to test navigation

      // Site A navigating to GitHub subdomain - should ALLOW
      expect(
        harness.simulateNavigation(0, 'https://gist.github.com'),
        isTrue,
        reason: 'GitHub site should allow navigation to gist.github.com',
      );

      // Site A navigating to GitLab - should BLOCK
      expect(
        harness.simulateNavigation(0, 'https://gitlab.com/user'),
        isFalse,
        reason: 'GitHub site should block navigation to gitlab.com',
      );
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitHub'));

      harness.clearLaunchUrlCalls();

      // Site B navigating to GitLab subdomain - should ALLOW
      expect(
        harness.simulateNavigation(1, 'https://registry.gitlab.com'),
        isTrue,
        reason: 'GitLab site should allow navigation to registry.gitlab.com',
      );

      // Site B navigating to GitHub - should BLOCK
      expect(
        harness.simulateNavigation(1, 'https://github.com/user'),
        isFalse,
        reason: 'GitLab site should block navigation to github.com',
      );
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitLab'));
    });

    test('bug scenario: site B should NOT use site A domain after switching', () {
      // This is the bug: click site A, click site B, site B opens links from site A as nested
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');
      // Sites created - ready to test navigation

      // Simulate: User clicks Site A (GitHub)
      // Simulate: User clicks Site B (GitLab)
      // Now on GitLab, user clicks a GitLab link

      // The BUG would be: GitLab navigation uses GitHub's domain check
      // EXPECTED: GitLab navigation uses GitLab's domain check

      // GitLab navigating to GitLab page - must use GitLab's initUrl
      final gitlabSite = harness.sites[1];
      final targetUrl = 'https://gitlab.com/explore';

      // Verify the domain comparison uses GitLab's initUrl, not GitHub's
      final targetNormalized = getNormalizedDomain(targetUrl);
      final gitlabNormalized = getNormalizedDomain(gitlabSite.initUrl);
      final githubNormalized = getNormalizedDomain(harness.sites[0].initUrl);

      expect(gitlabNormalized, equals('gitlab.com'));
      expect(githubNormalized, equals('github.com'));
      expect(targetNormalized, equals('gitlab.com'));

      // This is the critical assertion: GitLab should match its own domain
      expect(
        targetNormalized == gitlabNormalized,
        isTrue,
        reason: 'GitLab site should recognize gitlab.com as same domain',
      );

      // And NOT match GitHub's domain
      expect(
        targetNormalized == githubNormalized,
        isFalse,
        reason: 'gitlab.com should NOT match github.com',
      );

      // Simulate the navigation - should ALLOW (same domain)
      expect(
        harness.simulateNavigation(1, targetUrl),
        isTrue,
        reason: 'GitLab site should allow navigation within gitlab.com',
      );
    });

    test('domain aliases work correctly per site', () {
      // Gmail and Google are aliased for navigation
      harness.addSite('https://gmail.com', name: 'Gmail');
      harness.addSite('https://github.com', name: 'GitHub');
      // Sites created - ready to test navigation

      // Gmail navigating to Google (aliased) - should ALLOW
      expect(
        harness.simulateNavigation(0, 'https://accounts.google.com/signin'),
        isTrue,
        reason: 'Gmail should allow navigation to google.com (alias)',
      );

      // Gmail navigating to GitHub - should BLOCK
      expect(
        harness.simulateNavigation(0, 'https://github.com'),
        isFalse,
        reason: 'Gmail should block navigation to github.com',
      );
      expect(harness.launchUrlCalls.last.homeTitle, equals('Gmail'));

      harness.clearLaunchUrlCalls();

      // GitHub navigating to Google - should BLOCK (not aliased)
      expect(
        harness.simulateNavigation(1, 'https://google.com'),
        isFalse,
        reason: 'GitHub should block navigation to google.com',
      );
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitHub'));
    });

    test('three sites maintain correct domain identity', () {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');
      harness.addSite('https://bitbucket.org', name: 'Bitbucket');
      // Sites created - ready to test navigation

      // Each site should allow its own domain
      expect(harness.simulateNavigation(0, 'https://gist.github.com'), isTrue);
      expect(harness.simulateNavigation(1, 'https://registry.gitlab.com'), isTrue);
      expect(harness.simulateNavigation(2, 'https://bitbucket.org/user'), isTrue);

      // Each site should block other domains
      expect(harness.simulateNavigation(0, 'https://gitlab.com'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitHub'));

      expect(harness.simulateNavigation(1, 'https://bitbucket.org'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitLab'));

      expect(harness.simulateNavigation(2, 'https://github.com'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('Bitbucket'));
    });

    test('parallel loaded sites do not interfere with each other navigation', () {
      // Scenario: Both sites are loaded simultaneously (IndexedStack keeps both alive)
      // Navigation in one should not affect the other
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');
      harness.addSite('https://bitbucket.org', name: 'Bitbucket');
      // All sites created - simulating parallel loading in IndexedStack

      // Interleaved navigation requests from different sites
      // Site 0 (GitHub) navigates within its domain
      expect(harness.simulateNavigation(0, 'https://gist.github.com'), isTrue);

      // Site 1 (GitLab) navigates within its domain
      expect(harness.simulateNavigation(1, 'https://gitlab.com/explore'), isTrue);

      // Site 2 (Bitbucket) navigates within its domain
      expect(harness.simulateNavigation(2, 'https://bitbucket.org/account'), isTrue);

      // No cross-domain blocking should have occurred
      expect(harness.launchUrlCalls, isEmpty);

      // Now simulate cross-domain navigation from each site
      harness.clearLaunchUrlCalls();

      // GitHub tries to open GitLab - should block
      expect(harness.simulateNavigation(0, 'https://gitlab.com/repo'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitHub'));

      // GitLab tries to open Bitbucket - should block
      expect(harness.simulateNavigation(1, 'https://bitbucket.org/repo'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitLab'));

      // Bitbucket tries to open GitHub - should block
      expect(harness.simulateNavigation(2, 'https://github.com/repo'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('Bitbucket'));

      // Verify each blocked navigation was attributed to correct site
      expect(harness.launchUrlCalls.length, equals(3));
    });

    test('rapid switching between sites maintains correct domain checks', () {
      // Simulate rapid switching between sites - each should maintain its own domain
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      // Rapid interleaved navigations
      for (int i = 0; i < 5; i++) {
        // GitHub allows github.com
        expect(harness.simulateNavigation(0, 'https://github.com/page$i'), isTrue);
        // GitLab allows gitlab.com
        expect(harness.simulateNavigation(1, 'https://gitlab.com/page$i'), isTrue);
      }

      // No launchUrl calls - all navigations within own domain
      expect(harness.launchUrlCalls, isEmpty);

      // Now cross-domain - each should block with correct homeTitle
      expect(harness.simulateNavigation(0, 'https://gitlab.com'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitHub'));

      expect(harness.simulateNavigation(1, 'https://github.com'), isFalse);
      expect(harness.launchUrlCalls.last.homeTitle, equals('GitLab'));
    });
  });

  group('Widget Identity in IndexedStack', () {
    testWidgets('ValueKey ensures widget identity is preserved', (tester) async {
      // Create sites with unique siteIds
      final siteA = WebViewModel(initUrl: 'https://github.com', name: 'GitHub');
      final siteB = WebViewModel(initUrl: 'https://gitlab.com', name: 'GitLab');

      // Verify siteIds are unique
      expect(siteA.siteId, isNot(equals(siteB.siteId)));

      int currentIndex = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  // Simulate IndexedStack behavior with visibility
                  IndexedStack(
                    index: currentIndex,
                    children: [
                      Container(
                        key: ValueKey(siteA.siteId),
                        child: Text('Site A: ${siteA.initUrl}'),
                      ),
                      Container(
                        key: ValueKey(siteB.siteId),
                        child: Text('Site B: ${siteB.initUrl}'),
                      ),
                    ],
                  ),
                  ElevatedButton(
                    onPressed: () => setState(() => currentIndex = 1),
                    child: const Text('Switch to B'),
                  ),
                ],
              );
            },
          ),
        ),
      );

      // Verify initial state - use skipOffstage: false to find offstage widgets
      expect(find.text('Site A: https://github.com', skipOffstage: false), findsOneWidget);
      expect(find.text('Site B: https://gitlab.com', skipOffstage: false), findsOneWidget);

      // Switch to site B
      await tester.tap(find.text('Switch to B'));
      await tester.pump();

      // Both widgets should still exist (IndexedStack keeps both in tree)
      expect(find.text('Site A: https://github.com', skipOffstage: false), findsOneWidget);
      expect(find.text('Site B: https://gitlab.com', skipOffstage: false), findsOneWidget);

      // The key thing: widgets maintain their identity via ValueKey
      // This prevents Flutter from reusing/swapping widget state
    });

    testWidgets('without ValueKey, widgets might get confused', (tester) async {
      // This test documents the potential issue without proper keys
      final sites = [
        WebViewModel(initUrl: 'https://github.com', name: 'GitHub'),
        WebViewModel(initUrl: 'https://gitlab.com', name: 'GitLab'),
      ];

      // Track which initUrl each "widget" thinks it has
      final Map<int, String> capturedInitUrls = {};

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Column(
                children: [
                  for (int i = 0; i < sites.length; i++)
                    Builder(
                      key: ValueKey(sites[i].siteId), // With proper key
                      builder: (context) {
                        // Simulate callback capturing initUrl
                        capturedInitUrls[i] = sites[i].initUrl;
                        return Text('Site $i: ${sites[i].initUrl}');
                      },
                    ),
                ],
              );
            },
          ),
        ),
      );

      // Each widget captured the correct initUrl
      expect(capturedInitUrls[0], equals('https://github.com'));
      expect(capturedInitUrls[1], equals('https://gitlab.com'));
    });
  });

  group('Search Engine Redirect - Gesture Propagation', () {
    late NavigationTestHarness harness;

    setUp(() {
      harness = NavigationTestHarness();
    });

    test('DuckDuckGo redirect: same-domain click propagates gesture to cross-domain redirect', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // Step 1: User clicks a search result — DDG navigates to its redirect URL
      // (same domain, has gesture)
      final allowed = harness.simulateNavigation(
        0, 'https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.amazon.de',
        hasGesture: true,
      );
      expect(allowed, isTrue, reason: 'Same-domain redirect URL should be allowed');

      // Step 2: Server-side redirect fires shouldOverrideUrlLoading again
      // with the cross-domain target URL (no gesture — it is a redirect)
      final redirectResult = harness.simulateNavigation(
        0, 'https://www.amazon.de/',
        hasGesture: false,
      );
      expect(redirectResult, isFalse, reason: 'Cross-domain redirect should be blocked');
      expect(harness.launchUrlCalls.length, equals(1),
        reason: 'Nested webview should open for the redirect target');
      expect(harness.launchUrlCalls.last.url, equals('https://www.amazon.de/'));
    });

    test('Google redirect: same-domain click propagates gesture', () {
      harness.addSite('https://www.google.com', name: 'Google');

      // User clicks search result → google.com/url?q=... (same domain)
      harness.simulateNavigation(
        0, 'https://www.google.com/url?q=https%3A%2F%2Fexample.org',
        hasGesture: true,
      );

      // Redirect to example.org (cross-domain, no gesture)
      final result = harness.simulateNavigation(
        0, 'https://example.org/',
        hasGesture: false,
      );
      expect(result, isFalse);
      expect(harness.launchUrlCalls.last.url, equals('https://example.org/'));
    });

    test('gesture is consumed after one use — second redirect is blocked', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // User clicks a link (same-domain, gesture recorded)
      harness.simulateNavigation(
        0, 'https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com',
        hasGesture: true,
      );

      // First cross-domain redirect — gesture consumed, nested webview opens
      harness.simulateNavigation(
        0, 'https://example.com/',
        hasGesture: false,
      );
      expect(harness.launchUrlCalls.length, equals(1));

      harness.clearLaunchUrlCalls();

      // Second cross-domain navigation without gesture — should be blocked
      // (gesture already consumed, no nested webview)
      final result = harness.simulateNavigation(
        0, 'https://evil-tracker.com/',
        hasGesture: false,
      );
      expect(result, isFalse);
      expect(harness.launchUrlCalls, isEmpty,
        reason: 'Auto-redirect should be silently blocked (no gesture, consumed)');
    });

    test('script-initiated cross-domain without prior gesture is blocked', () {
      harness.addSite('https://example.com', name: 'Example');

      // Script-initiated cross-domain navigation (e.g., Google One Tap)
      // No prior same-domain gesture
      final result = harness.simulateNavigation(
        0, 'https://accounts.google.com/gsi',
        hasGesture: false,
      );
      expect(result, isFalse);
      expect(harness.launchUrlCalls, isEmpty,
        reason: 'Auto-redirect should be silently blocked');
    });

    test('direct cross-domain click still opens nested webview', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // User clicks a direct cross-domain link (has gesture)
      final result = harness.simulateNavigation(
        0, 'https://www.amazon.de/',
        hasGesture: true,
      );
      expect(result, isFalse);
      expect(harness.launchUrlCalls.length, equals(1));
      expect(harness.launchUrlCalls.last.url, equals('https://www.amazon.de/'));
    });

    test('blockAutoRedirects=false allows all cross-domain navigations', () {
      harness.addSite('https://example.com', name: 'Example',
        blockAutoRedirects: false);

      // Cross-domain without gesture — should open nested (not blocked)
      final result = harness.simulateNavigation(
        0, 'https://other.com/',
        hasGesture: false,
      );
      expect(result, isFalse);
      expect(harness.launchUrlCalls.length, equals(1),
        reason: 'With blockAutoRedirects=false, cross-domain should open nested');
    });
  });

  group('Cross-Domain Redirect Detection in onUrlChanged', () {
    late NavigationTestHarness harness;

    setUp(() {
      harness = NavigationTestHarness();
    });

    test('detects cross-domain URL that bypassed shouldOverrideUrlLoading', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // Simulate: server-side 302 redirect landed on amazon.de
      // without shouldOverrideUrlLoading firing
      final detected = harness.simulateUrlChanged(0, 'https://www.amazon.de/');
      expect(detected, isTrue);
      expect(harness.launchUrlCalls.length, equals(1));
      expect(harness.launchUrlCalls.last.url, equals('https://www.amazon.de/'));
    });

    test('same-domain URL change is not flagged', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      final detected = harness.simulateUrlChanged(
        0, 'https://duckduckgo.com/?q=test',
      );
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });

    test('captcha challenge URL is not flagged', () {
      harness.addSite('https://example.com', name: 'Example');

      final detected = harness.simulateUrlChanged(
        0, 'https://challenges.cloudflare.com/some-challenge',
      );
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });

    test('subdomain of same site is not flagged', () {
      harness.addSite('https://github.com', name: 'GitHub');

      final detected = harness.simulateUrlChanged(
        0, 'https://gist.github.com/user/123',
      );
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });

    test('data: URI is not flagged as cross-domain redirect', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      final detected = harness.simulateUrlChanged(
        0, 'data:text/html;charset=utf-8;base64,PCFET0NUWVBFIGh0bWw+',
      );
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });

    test('blob: URI is not flagged as cross-domain redirect', () {
      harness.addSite('https://example.com', name: 'Example');

      final detected = harness.simulateUrlChanged(
        0, 'blob:https://example.com/abc-123',
      );
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });
  });

  group('Inline URI Schemes (data:, blob:) in shouldOverrideUrlLoading', () {
    late NavigationTestHarness harness;

    setUp(() {
      harness = NavigationTestHarness();
    });

    test('data: URI is allowed without opening nested webview', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      final result = harness.simulateNavigation(
        0, 'data:text/html;charset=utf-8;base64,PCFET0NUWVBFIGh0bWw+',
      );
      expect(result, isTrue,
        reason: 'data: URI should be allowed as same-page inline content');
      expect(harness.launchUrlCalls, isEmpty,
        reason: 'data: URI should not open a nested webview');
    });

    test('blob: URI is allowed without opening nested webview', () {
      harness.addSite('https://example.com', name: 'Example');

      final result = harness.simulateNavigation(
        0, 'blob:https://example.com/550e8400-e29b-41d4-a716-446655440000',
      );
      expect(result, isTrue,
        reason: 'blob: URI should be allowed as same-origin inline content');
      expect(harness.launchUrlCalls, isEmpty,
        reason: 'blob: URI should not open a nested webview');
    });

    test('data: URI is allowed even with blockAutoRedirects enabled', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG',
        blockAutoRedirects: true);

      final result = harness.simulateNavigation(
        0, 'data:text/html;charset=utf-8;base64,PCFET0NUWVBFIGh0bWw+',
        hasGesture: false,
      );
      expect(result, isTrue,
        reason: 'data: URI should bypass cross-domain checks entirely');
    });
  });

  group('Closure Capture Verification', () {
    test('callback should capture correct initUrl from closure', () {
      final siteA = WebViewModel(initUrl: 'https://github.com', name: 'GitHub');
      final siteB = WebViewModel(initUrl: 'https://gitlab.com', name: 'GitLab');

      // Simulate what getWebView does - create callbacks that capture initUrl
      String? capturedInitUrlA;
      String? capturedInitUrlB;

      // Site A's callback
      final callbackA = () {
        capturedInitUrlA = siteA.initUrl;
        return getNormalizedDomain(siteA.initUrl);
      };

      // Site B's callback
      final callbackB = () {
        capturedInitUrlB = siteB.initUrl;
        return getNormalizedDomain(siteB.initUrl);
      };

      // Execute callbacks
      final domainA = callbackA();
      final domainB = callbackB();

      // Verify each callback captured its own site's initUrl
      expect(capturedInitUrlA, equals('https://github.com'));
      expect(capturedInitUrlB, equals('https://gitlab.com'));
      expect(domainA, equals('github.com'));
      expect(domainB, equals('gitlab.com'));
    });

    test('WebViewModel instances maintain independent state', () {
      final site1 = WebViewModel(initUrl: 'https://github.com', name: 'Site 1');
      final site2 = WebViewModel(initUrl: 'https://gitlab.com', name: 'Site 2');
      final site3 = WebViewModel(initUrl: 'https://bitbucket.org', name: 'Site 3');

      // Each has unique siteId
      final siteIds = {site1.siteId, site2.siteId, site3.siteId};
      expect(siteIds.length, equals(3), reason: 'All siteIds should be unique');

      // Each has correct initUrl
      expect(site1.initUrl, equals('https://github.com'));
      expect(site2.initUrl, equals('https://gitlab.com'));
      expect(site3.initUrl, equals('https://bitbucket.org'));

      // Modifying one doesn't affect others
      site1.currentUrl = 'https://github.com/user/repo';
      expect(site2.currentUrl, equals('https://gitlab.com'));
      expect(site3.currentUrl, equals('https://bitbucket.org'));
    });
  });
}
