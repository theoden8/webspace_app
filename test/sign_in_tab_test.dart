import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

/// NESTED-016: a sign-in a site's page sends its own tab to (a redirect to an
/// identity provider, no window) opens as a tab of the site under the tab it
/// left, and closes back into that tab when the provider sends it home.
///
/// The decisions are the engine's and [PopupKind]'s, replayed with the hops
/// of OpenAI's "Continue with Google" from ChatGPT as a real browser ran it
/// on 2026-10-31. The tab moves are [LinkController]'s over the tab flows,
/// held structurally, as LIR-032's are, since they need the page behind them.
void main() {
  const authorize = 'https://accounts.google.com/o/oauth2/v2/auth'
      '?client_id=app.apps.googleusercontent.com'
      '&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fapi%2Faccounts%2Fcallback%2Fgoogle'
      '&response_type=code&state=s';
  const callback =
      'https://auth.openai.com/api/accounts/callback/google?code=c&state=s';
  final t0 = DateTime(2026, 10, 31, 12);

  group('NESTED-016: what starts a sign-in tab', () {
    test('an authorization request on a sign-in host', () {
      expect(PopupKind.isSignInRequest(authorize), isTrue);
      expect(
          PopupKind.isSignInRequest(
              'https://github.com/login/oauth/authorize?scope=user&client_id=Iv1'),
          isTrue);
      expect(
          PopupKind.isSignInRequest(
              'https://appleid.apple.com/auth/authorize?client_id=com.example'),
          isTrue);
    });

    test('not the provider\'s own pages, nor another host\'s client_id', () {
      for (final url in [
        'https://github.com/theoden8/webspace_app',
        'https://accounts.google.com/v3/signin/identifier?flowName=x',
        'https://example.com/oauth/authorize?client_id=x',
        'http://accounts.google.com/o/oauth2/v2/auth?client_id=x',
        'https://accounts.google.com/o/oauth2/v2/auth?my_client_id=x',
      ]) {
        expect(PopupKind.isSignInRequest(url), isFalse, reason: url);
      }
    });

    test('a site\'s tab still decides the hop as leaving, which the routing '
        'takes over', () {
      final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
        targetUrl: authorize,
        initUrl: 'https://chatgpt.com/',
        hasGesture: true,
        frame: NavigationFrame.top,
        isSiteActive: true,
        lastSameDomainGestureTime: null,
        now: t0,
      );
      expect(result.decision, NavigationDecision.blockOpenNested);
      expect(result.hadGesture, isTrue);
    });
  });

  group('NESTED-016: the sign-in tab', () {
    tearDown(() => WebViewModel.siteLookup = null);

    WebViewModel chatgpt({required String home}) {
      final site = WebViewModel(
        siteId: SiteId('chatgpt'),
        initUrl: 'https://chatgpt.com/',
        tabs: [
          SiteTab.primary(url: 'https://auth.openai.com/log-in'),
          SiteTab(
            id: TabId('sign-in'),
            url: home,
            parentId: kPrimaryTabId,
            openerSiteId: SiteId('chatgpt'),
            homeUrl: home,
          ),
        ],
        activeTabId: TabId('sign-in'),
      );
      WebViewModel.siteLookup = (id) => id == site.siteId ? site : null;
      return site;
    }

    test('is the foreign tab a sign-in opened, and no other', () {
      final signIn = chatgpt(home: authorize);
      expect(signIn.runsForeignTab, isTrue);
      expect(signIn.runsSignInTab, isTrue);
      expect(signIn.isSignInTab(signIn.tabs.first), isFalse,
          reason: 'the tab it left is the site\'s own');
      final link = chatgpt(home: 'https://github.com/theoden8/webspace_app');
      expect(link.runsForeignTab, isTrue);
      expect(link.runsSignInTab, isFalse,
          reason: 'a link opened as a tab is not a sign-in');
    });

    test('holds the provider\'s sign-in hosts, and only those', () {
      final boundary = NavigationBoundary(
          homeUrl: authorize,
          initialUrl: authorize,
          signInHosts: PopupKind.isSignInUrl);
      for (final url in [
        'https://accounts.youtube.com/accounts/SetSID?ssdc=1',
        'https://accounts.google.de/accounts/SetSID',
        'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
      ]) {
        expect(boundary.contains(url), isTrue, reason: url);
      }
      expect(boundary.contains(callback), isFalse);
      expect(boundary.contains('https://example.org/'), isFalse);
      expect(
          NavigationBoundary(homeUrl: authorize, initialUrl: authorize)
              .contains('https://login.microsoftonline.com/common/oauth2/v2.0/authorize'),
          isFalse,
          reason: 'any other tab keeps its own domain');
    });

    test('runs Google\'s sign-in in place and returns with or without a tap',
        () {
      final boundary = NavigationBoundary(
          homeUrl: authorize,
          initialUrl: authorize,
          signInHosts: PopupKind.isSignInUrl);
      DateTime? lastGesture;
      NavigationDecision ask(String url, {required bool gesture, required int s}) {
        final at = t0.add(Duration(seconds: s));
        final result = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
          targetUrl: url,
          initUrl: authorize,
          hasGesture: gesture,
          frame: NavigationFrame.top,
          isSiteActive: true,
          lastSameDomainGestureTime: lastGesture,
          now: at,
          boundary: boundary,
        );
        lastGesture = result.gestureUpdate.applyTo(lastGesture, now: at);
        return result.decision;
      }

      for (final (url, gesture) in [
        ('https://accounts.google.com/v3/signin/identifier?flowName=x', false),
        ('https://accounts.google.com/v3/signin/challenge/pwd', true),
        ('https://accounts.youtube.com/accounts/SetSID?ssdc=1', false),
        ('https://accounts.google.de/accounts/SetSID', false),
        ('https://accounts.google.com/signin/oauth/consent', false),
      ]) {
        expect(ask(url, gesture: gesture, s: 30), NavigationDecision.allow,
            reason: url);
      }
      // Seconds after the last tap: the provider's own redirect home.
      final home = ask(callback, gesture: false, s: 90);
      expect(home, NavigationDecision.blockSilent);
      expect(
          NavigationDecisionEngine.stepFor(home,
              returnsToOwner: false, signInReturn: true),
          NavigationStep.returnToOwner);
      expect(
          NavigationDecisionEngine.stepFor(NavigationDecision.blockOpenNested,
              returnsToOwner: false, signInReturn: true),
          NavigationStep.returnToOwner,
          reason: 'a tap home returns too');
    });

    test('a gesture-less hop of any other tab is still dropped (NESTED-004)',
        () {
      expect(
          NavigationDecisionEngine.stepFor(NavigationDecision.blockSilent,
              returnsToOwner: true),
          NavigationStep.drop);
    });

    test('a site in the background returns nothing', () {
      expect(
          NavigationDecisionEngine.stepFor(NavigationDecision.blockSuppressed,
              returnsToOwner: false, signInReturn: true),
          NavigationStep.drop);
    });
  });

  group('NESTED-016: the wiring', () {
    late String links;
    late String model;
    late String page;

    setUpAll(() {
      links = File('lib/controllers/link_controller.dart').readAsStringSync();
      model = File('lib/web_view_model.dart').readAsStringSync();
      page = File('lib/screens/webspace_page.dart').readAsStringSync();
    });

    String bodyOf(String source, {required String signature}) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      return source.substring(start, source.indexOf('\n  }\n', start));
    }

    String flat(String s) => s.replaceAll(RegExp(r'\s'), '');

    test('a sign-in opens as a tab ahead of the link mode and tab routing', () {
      final route = bodyOf(links, signature: 'bool routeOutbound(');
      final signIn = route.indexOf('PopupKind.isSignInRequest(url)');
      expect(signIn, isNot(-1));
      expect(signIn,
          lessThan(route.indexOf('decision == NavigationDecision.blockOutbound')));
      expect(signIn, lessThan(route.indexOf('tabRouteFor(')));
      final f = flat(route);
      for (final gate in [
        'hadGesture&&PopupKind.isSignInRequest(url)&&source.effectiveSignInPopups&&_tabs.enabledFor(owner)&&!_host.kioskLocked',
        '_tabs.openChildTab(owner,url:url,hostSiteId:source.siteId,parentTabId:owner.activeTabId,openerSiteId:source.siteId,homeUrl:url)',
      ]) {
        expect(f, contains(gate), reason: gate);
      }
    });

    test('a sign-in tab closes back into the tab it was opened from', () {
      final body = bodyOf(links, signature: 'Future<void> returnToOwner(');
      final open = body.indexOf('await _tabs.openTab(model, tabId: opener);');
      final close = body.indexOf('await _tabs.closeTab(model, tabId: signIn.id);');
      final load = body.indexOf('await _loadInActiveTab(model, url: url);');
      expect([open, close, load], everyElement(isNot(-1)));
      expect(open, lessThan(close));
      expect(close, lessThan(load));
      expect(body, contains('!model.isSignInTab(signIn)'));
      expect(body, contains('await _tabs.returnToOwner(model, url: url);'),
          reason: 'any other foreign or hosted tab keeps S6');
      expect(flat(page),
          contains('(url)=>unawaited(_links.returnToOwner(site,url:url))'));
    });

    test('only an asked hop returns a sign-in tab; a late one stays put', () {
      final f = flat(model);
      expect(f, contains("via:'shouldOverrideUrlLoading',signInReturn:signInReturns(url));"));
      expect(f, contains('returnsToOwner:!signInTab&&returnsToOwner(url),signInReturn:signInReturn'));
      expect(f, contains("decision!=null&&!signInReturns(url)&&!dispatch(decision,url:url,hadGesture:handled.hadGesture,via:'onUrlChanged')"));
      expect(f, contains('signInHosts:signInTab?PopupKind.isSignInUrl:null'));
    });
  });
}
