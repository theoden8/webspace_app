import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/settings/external_links.dart';

const _home = 'https://theguardian.co.uk/';
const _canonical = 'https://www.theguardian.com/uk';
const _elsewhere = 'https://other.example/';
final _now = DateTime.utc(2026, 10, 18);

NavigationDecision _decide(
  NavigationBoundary boundary, {
  required String url,
  String home = _home,
  bool hasGesture = false,
  ExternalLinkMode mode = ExternalLinkMode.inApp,
}) => NavigationDecisionEngine.decideShouldOverrideUrlLoading(
  targetUrl: url,
  initUrl: home,
  boundary: boundary,
  frame: NavigationFrame.top,
  hasGesture: hasGesture,
  isSiteActive: true,
  lastSameDomainGestureTime: null,
  now: _now,
  externalLinkMode: mode,
).decision;

void main() {
  for (final redirectFlag in <bool?>[true, null]) {
    test(
      'initial HTTP redirect chain establishes the site ($redirectFlag)',
      () {
        final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
        for (final target in ['https://www.theguardian.com/', _canonical]) {
          boundary.onNavigation(
            target,
            frame: NavigationFrame.top,
            hasGesture: false,
            isRedirect: redirectFlag,
          );
          for (final mode in ExternalLinkMode.values) {
            expect(
              _decide(boundary, url: target, mode: mode),
              NavigationDecision.allow,
            );
          }
        }
        boundary.onCommit(_canonical);

        final handled = NavigationDecisionEngine.handleOnUrlChanged(
          newUrl: _canonical,
          initUrl: _home,
          boundary: boundary,
          isSiteActive: true,
          lastSameDomainGestureTime: null,
          now: _now,
          isCaptchaChallenge: (_) => false,
          state: OnUrlChangedState.initial(_home),
        );
        expect(handled.state.currentUrl, _canonical);
        expect(handled.navigateBackTo, isNull);
        expect(handled.launchNestedUrl, isNull);
        expect(
          _decide(boundary, url: 'https://www.theguardian.com/article'),
          NavigationDecision.allow,
        );
        expect(_decide(boundary, url: _home), NavigationDecision.allow);

        // Even a genuine HTTP redirect from an already-loaded page must go
        // through the existing gesture/outbound policy.
        boundary.onNavigation(
          _elsewhere,
          frame: NavigationFrame.top,
          hasGesture: false,
          isRedirect: true,
        );
        boundary.onCommit(_elsewhere);
        expect(
          _decide(boundary, url: _elsewhere),
          NavigationDecision.blockSilent,
        );
        expect(
          _decide(boundary, url: _elsewhere, hasGesture: true),
          NavigationDecision.blockOpenNested,
        );
      },
    );
  }

  test('an explicit non-redirect closes the initial exception', () {
    final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
    boundary.onNavigation(
      _home,
      frame: NavigationFrame.top,
      hasGesture: false,
      isRedirect: false,
    );
    boundary.onNavigation(
      _elsewhere,
      frame: NavigationFrame.top,
      hasGesture: false,
      isRedirect: false,
    );
    boundary.onCommit(_elsewhere);
    expect(_decide(boundary, url: _elsewhere), NavigationDecision.blockSilent);
  });

  test(
    'a user navigation ends the initial chain without adopting its domain',
    () {
      final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
      boundary.onNavigation(
        _elsewhere,
        frame: NavigationFrame.top,
        hasGesture: true,
        isRedirect: null,
      );
      boundary.onCommit(_elsewhere);
      expect(
        _decide(boundary, url: _elsewhere, hasGesture: true),
        NavigationDecision.blockOpenNested,
      );
      expect(boundary.contains(_elsewhere), isFalse);
    },
  );

  for (final frame in [NavigationFrame.sub, NavigationFrame.unverified]) {
    test('$frame cannot establish the top document domain', () {
      final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
      boundary.onNavigation(
        _elsewhere,
        frame: frame,
        hasGesture: false,
        isRedirect: true,
      );
      expect(boundary.contains(_elsewhere), isFalse);
      // A native main-document commit can still resolve a redirect which
      // did not have a verifiable navigation-action event (WebKit/Linux).
      boundary.onCommit(_canonical);
      expect(boundary.contains(_canonical), isTrue);
      expect(boundary.contains(_elsewhere), isFalse);
    });
  }

  test('blank placeholders do not finish the initial network navigation', () {
    final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
    for (final url in ['about:blank', 'about:srcdoc']) {
      boundary.onNavigation(
        url,
        frame: NavigationFrame.top,
        hasGesture: false,
        isRedirect: null,
      );
      boundary.onCommit(url);
      expect(boundary.contains(url), isFalse);
    }
    boundary.onCommit(_canonical);
    expect(boundary.contains(_canonical), isTrue);
  });

  for (final url in [
    'data:text/html,hello',
    'file:///page.html',
    'intent://open',
  ]) {
    test(
      'an inline or non-web document has no HTTP redirect exception ($url)',
      () {
        final boundary = NavigationBoundary(homeUrl: url, initialUrl: url);
        boundary.onNavigation(
          _elsewhere,
          frame: NavigationFrame.top,
          hasGesture: false,
          isRedirect: null,
        );
        boundary.onCommit(_elsewhere);
        expect(boundary.contains(_elsewhere), isFalse);
      },
    );
    test('a non-web document ends a pending network exception ($url)', () {
      final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home);
      boundary.onCommit(url);
      boundary.onNavigation(
        _elsewhere,
        frame: NavigationFrame.top,
        hasGesture: false,
        isRedirect: null,
      );
      boundary.onCommit(_elsewhere);
      expect(boundary.contains(_elsewhere), isFalse);
    });
  }

  test('cached executable HTML has no initial redirect exception', () {
    final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home)
      ..useExistingDocument();
    boundary.onNavigation(
      _elsewhere,
      frame: NavigationFrame.top,
      hasGesture: false,
      isRedirect: null,
    );
    boundary.onCommit(_elsewhere);
    expect(_decide(boundary, url: _elsewhere), NavigationDecision.blockSilent);
  });

  test(
    'recreating a resolved tab retains its original and canonical domains',
    () {
      final boundary = NavigationBoundary(
        homeUrl: _home,
        initialUrl: _canonical,
      )..useExistingDocument();
      expect(_decide(boundary, url: _home), NavigationDecision.allow);
      expect(_decide(boundary, url: _canonical), NavigationDecision.allow);
      expect(
        _decide(boundary, url: 'https://theguardian.com.other.example/'),
        NavigationDecision.blockSilent,
      );
    },
  );

  test('a nested screen still navigates within a later user-chosen domain', () {
    final boundary = NavigationBoundary(homeUrl: _home, initialUrl: _home)
      ..onCommit(_canonical);
    expect(
      _decide(boundary, home: _elsewhere, url: '${_elsewhere}article'),
      NavigationDecision.allow,
    );
  });
}
