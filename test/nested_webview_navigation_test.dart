import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

/// Test driver for the production `NavigationDecisionEngine`. Applies
/// the engine's `GestureStateUpdate` descriptors to per-site gesture
/// state the same way `WebViewModel.getWebView`'s closure does, so
/// production and the harness are exercising identical logic (not
/// parallel implementations).
class NavigationTestHarness {
  final List<WebViewModel> sites = [];

  /// Records of launchUrl calls: (url, homeTitle)
  final List<({String url, String? homeTitle})> launchUrlCalls = [];

  /// Per-site gesture propagation state (mirrors the local variables
  /// in WebViewModel.getWebView's closure).
  final Map<int, DateTime?> _lastSameDomainGestureTime = {};

  /// Per-site state for `simulateFullUrlChanged`. Owned by the harness; the
  /// harness delegates the actual decision to the production
  /// `NavigationDecisionEngine.handleOnUrlChanged` rather than re-implementing
  /// the redirect-handled/current-url logic.
  final Map<int, OnUrlChangedState> _urlChangedState = {};

  /// URLs the engine asked the call site to navigate the parent webview
  /// back to. Production no longer issues these as actual
  /// `controller.loadUrl` calls — the loadUrl-during-in-flight-cross-
  /// origin-redirect was a chromium dangling-raw_ptr trigger on the
  /// affected Android System WebView build — but the engine still
  /// computes the would-be target so the regression tests below can
  /// keep asserting that the engine picks a sane URL (not a redirector,
  /// not a stale cross-domain entry, etc.). The harness records the
  /// engine's request; production reads `result.navigateBackTo` and
  /// drops it on the floor.
  final List<({int siteIndex, String url})> loadUrlCalls = [];

  void addSite(String url, {String? name, bool blockAutoRedirects = true}) {
    sites.add(WebViewModel(
      initUrl: url,
      name: name ?? 'Site ${sites.length + 1}',
      blockAutoRedirects: blockAutoRedirects,
    ));
  }

  /// Simulates a `shouldOverrideUrlLoading` call by delegating to
  /// `NavigationDecisionEngine.decideShouldOverrideUrlLoading`. Returns
  /// `true` if the navigation would be allowed, `false` if cancelled.
  bool simulateNavigation(int siteIndex, String targetUrl, {bool hasGesture = true}) {
    final site = sites[siteIndex];
    final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
      targetUrl: targetUrl,
      initUrl: site.initUrl,
      hasGesture: hasGesture,
      blockAutoRedirects: site.blockAutoRedirects,
      isSiteActive: true,
      lastSameDomainGestureTime: _lastSameDomainGestureTime[siteIndex],
      now: DateTime.now(),
    );
    _applyGestureUpdate(siteIndex, result.gestureUpdate);
    switch (result.decision) {
      case NavigationDecision.allow:
        return true;
      case NavigationDecision.blockSilent:
      case NavigationDecision.blockSuppressed:
        return false;
      case NavigationDecision.blockOpenNested:
        launchUrlCalls.add((url: targetUrl, homeTitle: site.name));
        return false;
    }
  }

  /// Simulates an `onUrlChanged` call by delegating to
  /// `NavigationDecisionEngine.decideOnUrlChanged`. Returns `true`
  /// when a nested webview would be opened.
  bool simulateUrlChanged(int siteIndex, String newUrl) {
    final site = sites[siteIndex];
    final result = NavigationDecisionEngine.decideOnUrlChanged(
      newUrl: newUrl,
      initUrl: site.initUrl,
      blockAutoRedirects: site.blockAutoRedirects,
      isSiteActive: true,
      lastSameDomainGestureTime: _lastSameDomainGestureTime[siteIndex],
      now: DateTime.now(),
      isCaptchaChallenge: WebViewFactory.isCaptchaChallenge,
    );
    _applyGestureUpdate(siteIndex, result.gestureUpdate);
    if (result.decision == NavigationDecision.blockOpenNested) {
      launchUrlCalls.add((url: newUrl, homeTitle: site.name));
      return true;
    }
    return false;
  }

  /// Simulates a full onUrlChanged invocation by delegating to the
  /// production `NavigationDecisionEngine.handleOnUrlChanged`. The harness
  /// plays the caller's role: applies the gesture update, records
  /// loadUrl/launchNested side effects, and commits the new state back.
  /// Multi-event scenarios (duplicate onUrlChanged from onLoadStop+
  /// onUpdateVisitedHistory, followed by the loadUrl-back settling event)
  /// round-trip through the engine without a parallel implementation.
  void simulateFullUrlChanged(int siteIndex, String newUrl) {
    final site = sites[siteIndex];
    final prev = _urlChangedState[siteIndex] ??
        OnUrlChangedState.initial(site.initUrl);
    final result = NavigationDecisionEngine.handleOnUrlChanged(
      newUrl: newUrl,
      initUrl: site.initUrl,
      blockAutoRedirects: site.blockAutoRedirects,
      isSiteActive: true,
      lastSameDomainGestureTime: _lastSameDomainGestureTime[siteIndex],
      now: DateTime.now(),
      isCaptchaChallenge: WebViewFactory.isCaptchaChallenge,
      state: prev,
    );
    _applyGestureUpdate(siteIndex, result.gestureUpdate);
    if (result.navigateBackTo != null) {
      loadUrlCalls.add((siteIndex: siteIndex, url: result.navigateBackTo!));
    }
    if (result.launchNestedUrl != null) {
      launchUrlCalls.add((url: result.launchNestedUrl!, homeTitle: site.name));
    }
    _urlChangedState[siteIndex] = result.state;
  }

  /// Snapshot of the closure-level state for a site. Exposed so tests can
  /// assert post-condition invariants (e.g. previousSameDomainUrl stays on
  /// a same-domain URL after a handled cross-domain redirect).
  OnUrlChangedState stateFor(int siteIndex) =>
      _urlChangedState[siteIndex] ??
      OnUrlChangedState.initial(sites[siteIndex].initUrl);

  void _applyGestureUpdate(int siteIndex, GestureStateUpdate? update) {
    switch (update) {
      case GestureStateUpdate.record:
        _lastSameDomainGestureTime[siteIndex] = DateTime.now();
        break;
      case GestureStateUpdate.consume:
        _lastSameDomainGestureTime[siteIndex] = null;
        break;
      case null:
        break;
    }
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

    test('cross-domain redirect without gesture is silently blocked when blockAutoRedirects=true', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // No prior gesture — should be silently blocked (no nested webview)
      final detected = harness.simulateUrlChanged(0, 'https://www.amazon.de/');
      expect(detected, isFalse);
      expect(harness.launchUrlCalls, isEmpty);
    });

    test('cross-domain redirect without gesture opens nested when blockAutoRedirects=false', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG',
        blockAutoRedirects: false);

      final detected = harness.simulateUrlChanged(0, 'https://www.amazon.de/');
      expect(detected, isTrue);
      expect(harness.launchUrlCalls.length, equals(1));
      expect(harness.launchUrlCalls.last.url, equals('https://www.amazon.de/'));
    });

    test('cross-domain redirect with recent gesture opens nested even with blockAutoRedirects=true', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      // User clicks a same-domain link first (records gesture)
      harness.simulateNavigation(0, 'https://duckduckgo.com/?q=test', hasGesture: true);

      // Server-side 302 redirect to cross-domain — gesture should propagate
      final detected = harness.simulateUrlChanged(0, 'https://www.amazon.de/');
      expect(detected, isTrue);
      expect(harness.launchUrlCalls.length, equals(1));
      expect(harness.launchUrlCalls.last.url, equals('https://www.amazon.de/'));
    });

    test('LinkedIn safety/go redirector: same-domain click propagates gesture to cross-domain target', () {
      // LinkedIn wraps outbound links in https://www.linkedin.com/safety/go?url=<encoded>
      // The wrapper URL is same-domain (linkedin.com), so shouldOverrideUrlLoading
      // allows it and records the gesture. The server then redirects to the target
      // URL (cross-domain), which WKWebView surfaces only via onUrlChanged. The
      // gesture-propagation window should kick in so the redirect target opens
      // in a nested browser instead of overwriting the LinkedIn webview.
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      final allowed = harness.simulateNavigation(
        0,
        'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2FLocalLLaMA%2Fcomments%2F1srd2cc',
        hasGesture: true,
      );
      expect(allowed, isTrue, reason: 'safety/go wrapper is same-domain, must be allowed');

      final detected = harness.simulateUrlChanged(
        0,
        'https://www.reddit.com/r/LocalLLaMA/comments/1srd2cc',
      );
      expect(detected, isTrue,
        reason: 'redirect from safety/go must open a nested browser');
      expect(harness.launchUrlCalls.length, equals(1));
      expect(harness.launchUrlCalls.last.url,
        equals('https://www.reddit.com/r/LocalLLaMA/comments/1srd2cc'));
    });

    test('duplicate onUrlChanged (onLoadStop+onUpdateVisitedHistory) does not pollute currentUrl', () {
      // Regression: onUrlChanged fires twice for a cross-domain redirect
      // (once from onUpdateVisitedHistory, once from onLoadStop — see
      // lib/services/webview.dart:1247,1280). The decision block runs only
      // on the first pass because redirectHandled is set; the second pass
      // must NOT commit the cross-domain URL to currentUrl. If it did,
      // the next same-domain event would save it as previousSameDomainUrl
      // and the next cross-domain redirect's loadUrl-back would navigate
      // into a cross-domain URL (see "nth attempt" regression below).
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      // User lands on a messaging thread (same-domain gesture-less nav).
      harness.simulateFullUrlChanged(
        0, 'https://www.linkedin.com/mwlite/messaging/thread/foo');
      expect(
        harness.stateFor(0).currentUrl,
        equals('https://www.linkedin.com/mwlite/messaging/thread/foo'),
      );

      // User taps outbound link → safety/go wrapper loads, records gesture.
      harness.simulateNavigation(
        0,
        'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo',
        hasGesture: true,
      );
      harness.simulateFullUrlChanged(
        0, 'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo');

      // Server redirects to Reddit. onUrlChanged #1 fires (no slash).
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo');
      expect(harness.launchUrlCalls, hasLength(1));
      expect(harness.loadUrlCalls, hasLength(1),
        reason: 'navigate-back to the prior same-domain URL');
      expect(
        harness.loadUrlCalls.last.url,
        equals('https://www.linkedin.com/mwlite/messaging/thread/foo'),
        reason: 'navigate-back target is the pre-safety/go same-domain URL',
      );
      expect(harness.stateFor(0).redirectHandled, isTrue);

      // Duplicate onUrlChanged #2 fires (trailing slash / canonicalized).
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo/');
      expect(harness.launchUrlCalls, hasLength(1),
        reason: 'duplicate must not open a second nested browser');
      expect(
        harness.stateFor(0).currentUrl,
        isNot(startsWith('https://www.reddit.com')),
        reason: 'currentUrl must NOT be polluted with the cross-domain URL',
      );
      expect(
        harness.stateFor(0).currentUrl,
        startsWith('https://www.linkedin.com/'),
        reason: 'currentUrl must stay on a linkedin.com URL',
      );
    });

    test('inline scheme URLs (about:blank, data:, blob:) do not pollute previousSameDomainUrl', () {
      // Regression for the bug observed on a real device: after a
      // captcha / iframe / chromium-internal about:blank fired
      // onUrlChanged on the parent webview, the next same-domain
      // event saved "about:blank" as previousSameDomainUrl. The next
      // cross-domain redirect then navigated the parent webview to
      // about:blank instead of a real prior page — visible in the log
      // as: `navigating back from cross-domain "...reddit..." ->
      // "about:blank"`. The user ended up with a blank screen.
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      // Seed: user is on a real LinkedIn page.
      harness.simulateFullUrlChanged(0, 'https://www.linkedin.com/feed/');
      expect(harness.stateFor(0).currentUrl,
          equals('https://www.linkedin.com/feed/'));

      // about:blank fires (captcha iframe, intermediate chromium state,
      // page tear-down placeholder, etc.). It should NOT advance state.
      harness.simulateFullUrlChanged(0, 'about:blank');
      expect(harness.stateFor(0).currentUrl,
          equals('https://www.linkedin.com/feed/'),
          reason: 'about:blank must not be committed as currentUrl');

      // data: URI fires similarly.
      harness.simulateFullUrlChanged(
          0, 'data:text/html;charset=utf-8,<html></html>');
      expect(harness.stateFor(0).currentUrl,
          equals('https://www.linkedin.com/feed/'),
          reason: 'data: URI must not be committed as currentUrl');

      // blob: URI.
      harness.simulateFullUrlChanged(0, 'blob:https://example.com/abc-123');
      expect(harness.stateFor(0).currentUrl,
          equals('https://www.linkedin.com/feed/'),
          reason: 'blob: URI must not be committed as currentUrl');

      // Now a cross-domain redirect fires. previousSameDomainUrl
      // should still be the genuine prior page — NOT any inline
      // scheme — so the navigate-back target is a real LinkedIn URL.
      harness.simulateNavigation(
        0, 'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo',
        hasGesture: true,
      );
      harness.simulateFullUrlChanged(
          0, 'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo');
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo');

      expect(harness.loadUrlCalls, hasLength(1));
      expect(harness.loadUrlCalls.last.url,
          equals('https://www.linkedin.com/feed/'),
          reason: 'navigate-back target must be the real prior LinkedIn '
                  'page, never an inline scheme like about:blank');
    });

    test('navigate-back never targets a same-domain redirector URL the user is already on', () {
      // Regression for an infinite-redirect loop observed on Android
      // System WebView: tapping a link wrapped in a same-domain
      // redirector (e.g. linkedin.com/safety/go?url=reddit) eventually
      // crashed with `partition_alloc_support.cc:770 dangling raw_ptr`
      // on Chrome_IOThread. Trace from a real device:
      //
      //   onUrlChanged: navigating back from cross-domain
      //     "https://www.reddit.com/..." -> "https://www.linkedin.com/safety/go?url=..."
      //
      // The navigate-back was targeting the redirector itself, which
      // 302s back to reddit, which fires onUrlChanged(reddit) again —
      // infinite loop, eventually exhausts chromium's iframe / request
      // lifecycle bookkeeping and trips MiraclePtr.
      //
      // The bug: duplicate onUrlChanged events (onLoadStop +
      // onUpdateVisitedHistory both fire for the same URL) overwrote
      // previousSameDomainUrl with the URL the webview is already on,
      // losing the genuine prior page reference. The next cross-domain
      // event then used the redirector URL as its loadUrl-back target.
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      // Seed: user lands on a normal LinkedIn page.
      harness.simulateFullUrlChanged(0, 'https://www.linkedin.com/feed/');

      // User taps an outbound link. The webview navigates to the
      // redirector. onUrlChanged fires TWICE for the same URL (once
      // from each of the underlying chromium callbacks) before the
      // server-side redirect kicks in.
      harness.simulateNavigation(
        0,
        'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo',
        hasGesture: true,
      );
      const redirectorUrl =
          'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo';
      harness.simulateFullUrlChanged(0, redirectorUrl);
      // Duplicate event for the same URL — must NOT poison
      // previousSameDomainUrl by overwriting it with the redirector.
      harness.simulateFullUrlChanged(0, redirectorUrl);

      // Server 302s. Cross-domain event fires.
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo');

      expect(harness.loadUrlCalls, hasLength(1),
        reason: 'should issue exactly one navigate-back, not loop');
      expect(
        harness.loadUrlCalls.last.url,
        equals('https://www.linkedin.com/feed/'),
        reason: 'navigate-back must target the genuine prior page, '
                'not the redirector that put us on a cross-domain URL '
                '(which would 302 us right back into the same loop)',
      );
      expect(
        harness.loadUrlCalls.last.url,
        isNot(contains('safety/go')),
        reason: 'navigate-back to a known redirector pattern is the '
                'infinite-loop trap',
      );
    });

    test('nth attempt still navigates back to a same-domain URL, not the stale cross-domain one', () {
      // Regression for the bug observed in a real macOS session: after the
      // first safety/go → reddit redirect, currentUrl was committed to the
      // cross-domain URL by the duplicate onUrlChanged (from onLoadStop +
      // onUpdateVisitedHistory firing the same redirect twice). The next
      // same-domain settle then did `previousSameDomainUrl = currentUrl`
      // and saved the stale cross-domain URL. When WKWebView later served
      // the safety/go response from cache on a subsequent tap — skipping
      // the intermediate onUrlChanged(safety/go) that would have corrected
      // previousSameDomainUrl — the next cross-domain redirect's loadUrl
      // back target was the stale REDDIT URL. shouldOverrideUrlLoading
      // then CANCELed that (cross-domain, no gesture after consume), so
      // the "navigate back before the nested opens" cleanup was silently
      // dropped and the main webview stayed showing the Reddit content.
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      // Seed the state: user is mid-session on a messaging thread.
      harness.simulateFullUrlChanged(
        0, 'https://www.linkedin.com/mwlite/messaging/thread/foo');

      // === Attempt 1: happy path, full onUrlChanged chain ===
      harness.simulateNavigation(
        0,
        'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo',
        hasGesture: true,
      );
      harness.simulateFullUrlChanged(
        0, 'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo');
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo');
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo/'); // duplicate
      // loadUrl-back settles on the prior same-domain page.
      harness.simulateFullUrlChanged(
        0, 'https://www.linkedin.com/mwlite/messaging/thread/foo');

      expect(harness.launchUrlCalls, hasLength(1));
      expect(harness.loadUrlCalls.last.url,
        equals('https://www.linkedin.com/mwlite/messaging/thread/foo'));

      // === Attempt 2: WKWebView serves safety/go from cache, skipping the
      // intermediate onUrlChanged(safety/go) entirely. This is the critical
      // scenario for the regression — without the pollution guard, the
      // loadUrl-back on this attempt goes to the stale reddit URL. ===
      harness.simulateNavigation(
        0,
        'https://www.linkedin.com/safety/go?url=https%3A%2F%2Fwww.reddit.com%2Fr%2Ffoo',
        hasGesture: true,
      );
      // NOTE: no simulateFullUrlChanged(safety/go) — WKWebView skipped it.
      harness.simulateFullUrlChanged(0, 'https://www.reddit.com/r/foo');

      expect(harness.launchUrlCalls, hasLength(2),
        reason: 'attempt 2 must still open a nested browser');
      expect(harness.loadUrlCalls.last.url,
        startsWith('https://www.linkedin.com/'),
        reason: 'navigate-back must stay on linkedin.com — never reddit. '
                'A reddit URL here would be CANCELed by shouldOverrideUrlLoading '
                '(cross-domain, no gesture) and leave the Reddit page visible.');
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

    test('about:blank is not flagged as cross-domain redirect', () {
      harness.addSite('https://duckduckgo.com', name: 'DDG');

      final detected = harness.simulateUrlChanged(0, 'about:blank');
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
