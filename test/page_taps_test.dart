import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/page_taps.dart';

/// NESTED-017: on iOS a tap on the page counts as a gesture, experimentally,
/// since WebKit reports a navigation a button's script starts as `other`.
///
/// The recognizer is [PageTaps] over synthetic pointer events; the hops are
/// ChatGPT's Continue with Google as the iOS app logged them on 2026-10-31,
/// every one with no gesture; the wiring, which needs a platform view, is held
/// structurally.
void main() {
  group('NESTED-017: what is a tap', () {
    late int taps;
    late PageTaps recognizer;
    setUp(() {
      taps = 0;
      recognizer = PageTaps(onTap: () => taps++);
    });

    void down(int pointer,
            {required Offset at,
            int ms = 0,
            PointerDeviceKind kind = PointerDeviceKind.touch,
            int buttons = kPrimaryButton}) =>
        recognizer.down(PointerDownEvent(
            pointer: pointer,
            position: at,
            kind: kind,
            buttons: buttons,
            timeStamp: Duration(milliseconds: ms)));
    void move(int pointer, {required Offset at, int ms = 0}) => recognizer.move(
        PointerMoveEvent(
            pointer: pointer,
            position: at,
            timeStamp: Duration(milliseconds: ms)));
    void up(int pointer,
            {required Offset at,
            int ms = 100, PointerDeviceKind kind = PointerDeviceKind.touch}) =>
        recognizer.up(PointerUpEvent(
            pointer: pointer,
            position: at,
            kind: kind,
            timeStamp: Duration(milliseconds: ms)));

    test('a finger down and up in place is one tap', () {
      down(1, at: const Offset(100, 200));
      move(1, at: const Offset(104, 203), ms: 40);
      up(1, at: const Offset(104, 203));
      expect(taps, 1);
    });

    test('a scroll is none', () {
      down(1, at: const Offset(100, 200));
      move(1, at: const Offset(100, 260), ms: 40);
      move(1, at: const Offset(100, 201), ms: 80);
      up(1, at: const Offset(100, 201));
      expect(taps, 0, reason: 'past the slop once spoils it, even back home');
    });

    test('a pinch is none', () {
      down(1, at: const Offset(100, 200));
      down(2, at: const Offset(200, 300), ms: 10);
      up(2, at: const Offset(200, 300), ms: 90);
      up(1, at: const Offset(100, 200));
      expect(taps, 0);
    });

    test('a long press is none', () {
      down(1, at: const Offset(100, 200));
      up(1, at: const Offset(100, 200), ms: kLongPressTimeout.inMilliseconds + 1);
      expect(taps, 0);
    });

    test('a cancelled touch is none, and the next tap still counts', () {
      down(1, at: const Offset(100, 200));
      recognizer.cancel(const PointerCancelEvent(pointer: 1));
      up(1, at: const Offset(100, 200));
      expect(taps, 0);
      down(2, at: const Offset(100, 200), ms: 200);
      up(2, at: const Offset(100, 200), ms: 260);
      expect(taps, 1);
    });

    test('a click asks for the primary button and a mouse\'s own slop', () {
      down(1, at: const Offset(10, 10),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      up(1, at: const Offset(10, 10), kind: PointerDeviceKind.mouse);
      expect(taps, 0, reason: 'a right click is no tap');
      down(2, at: const Offset(10, 10), kind: PointerDeviceKind.mouse);
      move(2, at: const Offset(16, 10), ms: 20);
      up(2, at: const Offset(16, 10), kind: PointerDeviceKind.mouse);
      expect(taps, 0, reason: 'a mouse drags well inside a finger\'s slop');
    });
  });

  group('NESTED-017: Continue with Google from ChatGPT on iOS', () {
    const home = 'https://chatgpt.com/';
    const loginWith = 'https://chatgpt.com/auth/login_with'
        '?connection=google-oauth2&screen_hint=login_or_signup';
    const authorize = 'https://auth.openai.com/oauth/authorize'
        '?client_id=app_x&response_type=code'
        '&redirect_uri=https%3A%2F%2Fchatgpt.com%2Fapi%2Fauth%2Fcallback%2Fopenai';
    const google = 'https://accounts.google.com/o/oauth2/v2/auth'
        '?response_type=code&client_id=7.apps.googleusercontent.com'
        '&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fapi%2Faccounts%2Fcallback%2Fgoogle';
    final t0 = DateTime(2026, 10, 31, 14, 21, 24);

    /// The hops as WebKit reported them, every one with no gesture, against a
    /// gesture time a tap may have set; the hop to Google arrives by
    /// `onUrlChanged` first, as it did, then by `shouldOverrideUrlLoading`.
    (NavigationDecisionResult, NavigationDecision) replay(
        {required DateTime? tappedAt}) {
      var gesture = tappedAt;
      for (final (i, url) in [loginWith, authorize].indexed) {
        final at = t0.add(Duration(milliseconds: 200 * (i + 1)));
        final r = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
          targetUrl: url,
          initUrl: home,
          hasGesture: false,
          frame: NavigationFrame.top,
          isSiteActive: true,
          lastSameDomainGestureTime: gesture,
          now: at,
        );
        expect(r.decision, NavigationDecision.allow, reason: url);
        gesture = r.gestureUpdate.applyTo(gesture, now: at);
      }
      final at = t0.add(const Duration(seconds: 1));
      final changed = NavigationDecisionEngine.decideOnUrlChanged(
        newUrl: google,
        initUrl: home,
        isSiteActive: true,
        lastSameDomainGestureTime: gesture,
        now: at,
        isCaptchaChallenge: (_) => false,
      );
      gesture = changed.gestureUpdate.applyTo(gesture, now: at);
      final asked = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: google,
        initUrl: home,
        hasGesture: false,
        frame: NavigationFrame.top,
        isSiteActive: true,
        lastSameDomainGestureTime: gesture,
        now: at,
      );
      return (changed, asked.decision);
    }

    test('with no tap the hop to Google is dropped (NESTED-004)', () {
      final (changed, asked) = replay(tappedAt: null);
      expect(changed.decision, NavigationDecision.blockSilent);
      expect(asked, NavigationDecision.blockSilent);
    });

    test('a tap carries into the hop to Google, once, and routes it', () {
      final (changed, asked) = replay(tappedAt: t0);
      expect(changed.decision, NavigationDecision.blockOpenNested);
      expect(changed.hadGesture, isTrue);
      expect(
          NavigationDecisionEngine.stepFor(changed.decision,
              returnsToOwner: false),
          NavigationStep.route,
          reason: 'routing opens the sign-in tab (NESTED-016)');
      expect(asked, NavigationDecision.blockSilent,
          reason: 'the second report of the same hop finds the tap spent');
    });

    test('a tap more than 10 seconds before is spent', () {
      final (changed, _) =
          replay(tappedAt: t0.subtract(const Duration(seconds: 10)));
      expect(changed.decision, NavigationDecision.blockSilent);
    });
  });

  group('NESTED-017: the wiring', () {
    String flat(String s) => s.replaceAll(RegExp(r'\s'), '');

    test('a raw Listener feeds the taps, offered on iOS, read per tap', () {
      final taps = File('lib/services/page_taps.dart').readAsStringSync();
      final start = taps.indexOf('static Widget around(');
      expect(start, isNot(-1));
      final body = flat(taps.substring(start, taps.indexOf('\n  }\n', start)));
      for (final piece in [
        'if(onPageTap==null||!offered)returnwebView;',
        'if(!countAsGestures)return;',
        'Listener(',
        'onPointerDown:taps.down',
        'onPointerMove:taps.move',
        'onPointerUp:taps.up',
        'onPointerCancel:taps.cancel',
      ]) {
        expect(body, contains(piece), reason: piece);
      }
      expect(
          flat(File('lib/services/webview.dart').readAsStringSync()),
          contains('webView:PageTaps.around(config.pullToRefreshGate?.around(focused)??focused,'
              'onPageTap:config.onPageTap)'));
    });

    test('a tap records a gesture on the site\'s page and a nested screen\'s',
        () {
      expect(
          flat(File('lib/web_view_model.dart').readAsStringSync()),
          contains(
              'onPageTap:()=>lastSameDomainGestureTime=DateTime.now(),'));
      expect(
          flat(File('lib/screens/inappbrowser.dart').readAsStringSync()),
          contains(
              'onPageTap:()=>_lastSameDomainGestureTime=DateTime.now(),'));
    });

    test('the switch is listed where taps are offered', () {
      expect(
          flat(File('lib/screens/app_developer.dart').readAsStringSync()),
          contains('if(PageTaps.offered)(ExperimentalFeature.tapGestures,'));
    });
  });
}
