import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

/// Test harness that simulates shouldOverrideUrlLoading behavior.
/// This tests the domain comparison logic without requiring actual webviews.
class NavigationTestHarness {
  final List<WebViewModel> sites = [];

  /// Records of launchUrl calls: (url, homeTitle)
  final List<({String url, String? homeTitle})> launchUrlCalls = [];

  void addSite(String url, {String? name}) {
    sites.add(WebViewModel(
      initUrl: url,
      name: name ?? 'Site ${sites.length + 1}',
    ));
  }

  /// Simulates a navigation request on a specific site's webview.
  /// This replicates the exact logic from WebViewModel.getWebView's
  /// shouldOverrideUrlLoading callback.
  /// Returns true if navigation was allowed, false if blocked (opened nested)
  bool simulateNavigation(int siteIndex, String targetUrl) {
    final site = sites[siteIndex];

    // Replicate the exact logic from WebViewModel.getWebView
    final requestNormalized = getNormalizedDomain(targetUrl);
    final initialNormalized = getNormalizedDomain(site.initUrl);

    if (requestNormalized == initialNormalized) {
      return true; // Allow - same logical domain
    }

    // Would block and call launchUrl with site's name as homeTitle
    launchUrlCalls.add((url: targetUrl, homeTitle: site.name));
    return false; // Cancel - open in nested webview
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
