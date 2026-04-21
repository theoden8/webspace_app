import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';

bool _neverCaptcha(String _) => false;
bool _alwaysCaptcha(String _) => true;

void main() {
  final t0 = DateTime.parse('2026-04-21T12:00:00Z');

  NavigationDecisionResult decideShould({
    required String targetUrl,
    required String initUrl,
    bool hasGesture = false,
    bool blockAutoRedirects = true,
    bool isSiteActive = true,
    DateTime? lastSameDomainGestureTime,
    DateTime? now,
  }) =>
      NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: targetUrl,
        initUrl: initUrl,
        hasGesture: hasGesture,
        blockAutoRedirects: blockAutoRedirects,
        isSiteActive: isSiteActive,
        lastSameDomainGestureTime: lastSameDomainGestureTime,
        now: now ?? t0,
      );

  NavigationDecisionResult decideChanged({
    required String newUrl,
    required String initUrl,
    bool blockAutoRedirects = true,
    bool isSiteActive = true,
    DateTime? lastSameDomainGestureTime,
    DateTime? now,
    bool Function(String)? isCaptcha,
  }) =>
      NavigationDecisionEngine.decideOnUrlChanged(
        newUrl: newUrl,
        initUrl: initUrl,
        blockAutoRedirects: blockAutoRedirects,
        isSiteActive: isSiteActive,
        lastSameDomainGestureTime: lastSameDomainGestureTime,
        now: now ?? t0,
        isCaptchaChallenge: isCaptcha ?? _neverCaptcha,
      );

  group('decideShouldOverrideUrlLoading', () {
    test('allows about:blank for captcha iframes', () {
      final r = decideShould(targetUrl: 'about:blank', initUrl: 'https://example.com');
      expect(r.decision, NavigationDecision.allow);
      expect(r.gestureUpdate, isNull);
    });

    test('allows about:srcdoc for captcha iframes', () {
      final r = decideShould(targetUrl: 'about:srcdoc', initUrl: 'https://example.com');
      expect(r.decision, NavigationDecision.allow);
    });

    test('allows data: URIs', () {
      final r = decideShould(
        targetUrl: 'data:text/html,<p>hi</p>',
        initUrl: 'https://example.com',
      );
      expect(r.decision, NavigationDecision.allow);
    });

    test('allows blob: URIs', () {
      final r = decideShould(
        targetUrl: 'blob:https://example.com/uuid',
        initUrl: 'https://example.com',
      );
      expect(r.decision, NavigationDecision.allow);
    });

    test('allows same normalized domain without gesture (no record)', () {
      final r = decideShould(
        targetUrl: 'https://www.example.com/page',
        initUrl: 'https://example.com',
      );
      expect(r.decision, NavigationDecision.allow);
      expect(r.gestureUpdate, isNull);
    });

    test('allows same normalized domain with gesture (records)', () {
      final r = decideShould(
        targetUrl: 'https://duckduckgo.com/l/?uddg=...',
        initUrl: 'https://duckduckgo.com',
        hasGesture: true,
      );
      expect(r.decision, NavigationDecision.allow);
      expect(r.gestureUpdate, GestureStateUpdate.record);
    });

    test('blocks script-initiated cross-domain silently when blockAutoRedirects', () {
      final r = decideShould(
        targetUrl: 'https://evil.tracker.com',
        initUrl: 'https://example.com',
        hasGesture: false,
      );
      expect(r.decision, NavigationDecision.blockSilent);
    });

    test('opens nested on gesture-driven cross-domain click', () {
      final r = decideShould(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: true,
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
      expect(r.gestureUpdate, isNull, reason: 'direct gesture — nothing to consume');
    });

    test('suppresses nested open when background site', () {
      final r = decideShould(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: true,
        isSiteActive: false,
      );
      expect(r.decision, NavigationDecision.blockSuppressed);
    });

    test('propagates gesture within 10s window (DDG redirect scenario)', () {
      final click = t0;
      final redirect = t0.add(const Duration(seconds: 3));
      final r = decideShould(
        targetUrl: 'https://www.amazon.de/',
        initUrl: 'https://duckduckgo.com',
        hasGesture: false,
        lastSameDomainGestureTime: click,
        now: redirect,
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
      expect(r.gestureUpdate, GestureStateUpdate.consume);
    });

    test('does not propagate gesture older than 10s', () {
      final r = decideShould(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: false,
        lastSameDomainGestureTime: t0,
        now: t0.add(const Duration(seconds: 11)),
      );
      expect(r.decision, NavigationDecision.blockSilent);
      expect(r.gestureUpdate, GestureStateUpdate.consume,
          reason: 'still consumed even when stale, to prevent a later in-window use');
    });

    test('allows cross-domain when blockAutoRedirects is off', () {
      final r = decideShould(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: false,
        blockAutoRedirects: false,
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
    });

    test('blockAutoRedirects=false still suppresses nested for background sites', () {
      final r = decideShould(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: false,
        blockAutoRedirects: false,
        isSiteActive: false,
      );
      expect(r.decision, NavigationDecision.blockSuppressed);
    });
  });

  group('decideOnUrlChanged', () {
    test('allows data/blob/about schemes as no-op', () {
      for (final url in const ['data:text/html,x', 'blob:https://x/uuid', 'about:blank']) {
        final r = decideChanged(newUrl: url, initUrl: 'https://example.com');
        expect(r.decision, NavigationDecision.allow, reason: 'url=$url');
      }
    });

    test('allows same-domain URL changes without touching gesture state', () {
      final r = decideChanged(
        newUrl: 'https://example.com/other',
        initUrl: 'https://example.com',
        lastSameDomainGestureTime: t0.subtract(const Duration(seconds: 2)),
      );
      expect(r.decision, NavigationDecision.allow);
      expect(r.gestureUpdate, isNull, reason: 'same-domain changes do not touch gesture state');
    });

    test('allows captcha challenge URLs even when cross-domain', () {
      final r = decideChanged(
        newUrl: 'https://challenges.cloudflare.com/foo',
        initUrl: 'https://example.com',
        isCaptcha: _alwaysCaptcha,
      );
      expect(r.decision, NavigationDecision.allow);
    });

    test('silently blocks server-side redirect when no recent gesture', () {
      final r = decideChanged(
        newUrl: 'https://tracker.com',
        initUrl: 'https://example.com',
      );
      expect(r.decision, NavigationDecision.blockSilent);
    });

    test('opens nested when server-side redirect inherits recent gesture', () {
      final r = decideChanged(
        newUrl: 'https://www.amazon.de/',
        initUrl: 'https://duckduckgo.com',
        lastSameDomainGestureTime: t0.subtract(const Duration(seconds: 2)),
        now: t0,
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
      expect(r.gestureUpdate, GestureStateUpdate.consume);
    });

    test('suppresses redirect handling for background site', () {
      final r = decideChanged(
        newUrl: 'https://other.com',
        initUrl: 'https://example.com',
        isSiteActive: false,
        lastSameDomainGestureTime: t0.subtract(const Duration(seconds: 2)),
      );
      expect(r.decision, NavigationDecision.blockSuppressed);
    });

    test('allows cross-domain redirect when blockAutoRedirects=false and no gesture', () {
      final r = decideChanged(
        newUrl: 'https://other.com',
        initUrl: 'https://example.com',
        blockAutoRedirects: false,
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
    });
  });

  group('gesture window boundary behaviour', () {
    test('exactly at 9s still propagates', () {
      final r = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: false,
        blockAutoRedirects: true,
        isSiteActive: true,
        lastSameDomainGestureTime: t0,
        now: t0.add(const Duration(seconds: 9)),
      );
      expect(r.decision, NavigationDecision.blockOpenNested);
    });

    test('exactly at 10s does not propagate', () {
      final r = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: 'https://other.com',
        initUrl: 'https://example.com',
        hasGesture: false,
        blockAutoRedirects: true,
        isSiteActive: true,
        lastSameDomainGestureTime: t0,
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(r.decision, NavigationDecision.blockSilent);
    });
  });
}
