import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/settings_import_engine.dart';
import 'package:webspace/web_view_model.dart';

class _Site implements DispatchableSite {
  @override
  final String siteId;
  @override
  final String initUrl;
  @override
  final List<DomainClaim> domainClaims;
  @override
  bool get incognito => false;
  @override
  bool get alwaysOpenHome => false;

  _Site(this.siteId, this.initUrl, this.domainClaims);

  @override
  String get navigationDomain => getNormalizedDomain(initUrl);
}

OutboundPreference pref(DomainClaim claim, String target) =>
    OutboundPreference(claim: claim, targetSiteId: target);

final ddg = _Site('ddg', 'https://duckduckgo.com/',
    [DomainClaim.baseDomain('duckduckgo.com')]);
final workGh = _Site(
    'work-gh', 'https://github.com/', [DomainClaim.exactHost('github.com')]);
final personalGh = _Site('personal-gh', 'https://github.com/?personal',
    [DomainClaim.baseDomain('github.com')]);

void main() {
  group('LIR-014 resolveOutbound', () {
    final gh = Uri.parse('https://github.com/x');

    test('a source preference beats a global single match', () {
      final r = LinkRoutingService.resolveOutbound(
        gh,
        'ddg',
        [pref(DomainClaim.exactHost('github.com'), 'work-gh')],
        [ddg, personalGh, workGh],
      );
      expect(r, isA<OutboundByPreference>());
      expect((r as OutboundByPreference).site.siteId, 'work-gh');
    });

    test('even a weaker preference beats a stronger global claim', () {
      final r = LinkRoutingService.resolveOutbound(
        gh,
        'ddg',
        [pref(DomainClaim.baseDomain('github.com'), 'personal-gh')],
        [ddg, personalGh, workGh],
      );
      expect((r as OutboundByPreference).site.siteId, 'personal-gh');
    });

    test('a preference whose target is not a candidate is skipped', () {
      final r = LinkRoutingService.resolveOutbound(
        gh,
        'ddg',
        [pref(DomainClaim.exactHost('github.com'), 'work-gh')],
        [ddg, personalGh],
      );
      expect(r, isA<OutboundByClaims>());
      final m = (r as OutboundByClaims).match as RoutingSingle;
      expect(m.site.siteId, 'personal-gh');
    });

    test('the more specific preference wins; equal scores keep list order', () {
      final gist = Uri.parse('https://gist.github.com/abc');
      final specific = LinkRoutingService.resolveOutbound(
        gist,
        'ddg',
        [
          pref(DomainClaim.baseDomain('github.com'), 'personal-gh'),
          pref(DomainClaim.exactHost('gist.github.com'), 'work-gh'),
        ],
        [ddg, personalGh, workGh],
      );
      expect((specific as OutboundByPreference).site.siteId, 'work-gh');

      final tie = LinkRoutingService.resolveOutbound(
        gist,
        'ddg',
        [
          pref(DomainClaim.wildcardSubdomain('github.com'), 'personal-gh'),
          pref(DomainClaim.wildcardSubdomain('github.com'), 'work-gh'),
        ],
        [ddg, personalGh, workGh],
      );
      expect((tie as OutboundByPreference).site.siteId, 'personal-gh');
    });

    test('ambiguity passes through when no preference matches', () {
      final twin = _Site('twin-gh', 'https://github.com/?twin',
          [DomainClaim.exactHost('github.com')]);
      final r = LinkRoutingService.resolveOutbound(
          gh, 'ddg', const [], [ddg, workGh, twin]);
      final m = (r as OutboundByClaims).match;
      expect(m, isA<RoutingAmbiguous>());
    });

    test('a result naming the source collapses to selfMatch', () {
      final masto = _Site('masto', 'https://mastodon.social/', [
        DomainClaim.baseDomain('mastodon.social'),
        DomainClaim.exactHost('joinmastodon.org'),
      ]);
      final viaClaim = LinkRoutingService.resolveOutbound(
          Uri.parse('https://joinmastodon.org/apps'), 'masto', const [],
          [masto, workGh]);
      expect(viaClaim, isA<OutboundSelfMatch>());

      final viaPref = LinkRoutingService.resolveOutbound(
          gh, 'ddg', [pref(DomainClaim.exactHost('github.com'), 'ddg')],
          [ddg, workGh]);
      expect(viaPref, isA<OutboundSelfMatch>());
    });

    test('a port-bearing URL scores like resolve', () {
      final local = _Site('local', 'http://localhost:8080/',
          [DomainClaim.exactHost('localhost:8080')]);
      final r = LinkRoutingService.resolveOutbound(
          Uri.parse('http://localhost:8080/app'), 'ddg', const [],
          [ddg, local]);
      expect(((r as OutboundByClaims).match as RoutingSingle).site.siteId,
          'local');
      final wrongPort = LinkRoutingService.resolveOutbound(
          Uri.parse('http://localhost:9090/app'), 'ddg', const [],
          [ddg, local]);
      expect((wrongPort as OutboundByClaims).match, isA<RoutingNone>());
    });
  });

  group('LIR-015 dispatchOutbound', () {
    final gh = Uri.parse('https://github.com/x');

    DispatchAction run({
      List<OutboundPreference> prefs = const [],
      List<DispatchableSite>? candidates,
      OutboundFallback fallback = OutboundFallback.nested,
      bool hadGesture = true,
      bool containersActive = true,
      Uri? url,
    }) =>
        LinkIntentDispatchEngine.dispatchOutbound(
          targetUrl: url ?? gh,
          source: ddg,
          sourcePrefs: prefs,
          candidates: candidates ?? [ddg, workGh],
          fallback: fallback,
          hadGesture: hadGesture,
          containersActive: containersActive,
        );

    test('a single match opens the destination nested over the source', () {
      final a = run() as DispatchOpenNested;
      expect(a.siteId, 'work-gh');
      expect(a.url, gh.toString());
      expect(a.sourceIsParent, isTrue);
    });

    test('a preference opens its target', () {
      final a = run(
        prefs: [pref(DomainClaim.exactHost('github.com'), 'personal-gh')],
        candidates: [ddg, workGh, personalGh],
      ) as DispatchOpenNested;
      expect(a.siteId, 'personal-gh');
    });

    test('ambiguity shows the outbound picker', () {
      final twin = _Site('twin-gh', 'https://github.com/?twin',
          [DomainClaim.exactHost('github.com')]);
      final a = run(
        candidates: [ddg, workGh, twin],
        fallback: OutboundFallback.external,
      ) as DispatchShowPicker;
      expect(a.winnerSiteIds, ['work-gh', 'twin-gh']);
      expect(a.offerBind, isFalse);
      expect(a.offerCreate, isFalse);
      expect(a.source, 'ddg');
      expect(a.fallback, OutboundFallback.external);
    });

    test('no match keeps the navigation engine decision', () {
      final blog = Uri.parse('https://blog.example/post');
      expect(run(url: blog), isA<DispatchNestedFallback>());
      final ext = run(url: blog, fallback: OutboundFallback.external);
      expect((ext as DispatchOpenExternal).url, blog.toString());
    });

    test('a routed destination wins over the system browser', () {
      expect(run(fallback: OutboundFallback.external),
          isA<DispatchOpenNested>());
    });

    test('a gesture-less navigation is not routed', () {
      expect(run(hadGesture: false), isA<DispatchNestedFallback>());
      expect(run(hadGesture: false, fallback: OutboundFallback.external),
          isA<DispatchOpenExternal>());
    });

    test('the legacy engine does not route', () {
      expect(run(containersActive: false), isA<DispatchNestedFallback>());
    });

    test('a self-match keeps the fallback', () {
      final a = run(
        prefs: [pref(DomainClaim.exactHost('github.com'), 'ddg')],
      );
      expect(a, isA<DispatchNestedFallback>());
    });
  });

  group('LIR-014 routeOutbound gates', () {
    const url = 'https://github.com/x';
    var candidateReads = 0;

    DispatchAction? route({
      NavigationDecision decision = NavigationDecision.blockOpenNested,
      bool routeOutboundLinks = true,
      bool kioskLocked = false,
      bool hadGesture = true,
      bool containersActive = true,
      String link = url,
    }) =>
        LinkIntentDispatchEngine.routeOutbound(
          url: link,
          decision: decision,
          routeOutboundLinks: routeOutboundLinks,
          kioskLocked: kioskLocked,
          hadGesture: hadGesture,
          containersActive: containersActive,
          source: ddg,
          sourcePrefs: const [],
          candidates: () {
            candidateReads++;
            return [ddg, workGh];
          },
        );

    setUp(() => candidateReads = 0);

    test('every gate open: a claimed link is routed', () {
      final a = route() as DispatchOpenNested;
      expect(a.siteId, 'work-gh');
      expect(a.sourceIsParent, isTrue);
      final ext =
          route(decision: NavigationDecision.blockOpenExternal)!;
      expect(ext, isA<DispatchOpenNested>());
    });

    test('routing off or a locked kiosk hand it back', () {
      expect(route(routeOutboundLinks: false), isNull);
      expect(route(kioskLocked: true), isNull);
      expect(candidateReads, 0,
          reason: 'candidates are only built once the cheap gates pass');
    });

    test('only a nested or external launch is routed', () {
      for (final d in [
        NavigationDecision.allow,
        NavigationDecision.blockSilent,
        NavigationDecision.blockSuppressed,
      ]) {
        expect(route(decision: d), isNull, reason: '$d');
      }
    });

    test('no gesture, the legacy engine or no claim hand it back', () {
      expect(route(hadGesture: false), isNull);
      expect(route(containersActive: false), isNull);
      expect(route(link: 'https://blog.example/post'), isNull);
      expect(
        route(
          link: 'https://blog.example/post',
          decision: NavigationDecision.blockOpenExternal,
        ),
        isNull,
        reason: 'an unrouted external link goes to the browser as before',
      );
    });
  });

  group('LIR-016 pickOutbound', () {
    final gh = Uri.parse('https://github.com/x');

    test('a remembered pick adds the claims and opens over the source', () {
      final pick = LinkIntentDispatchEngine.pickOutbound(
        url: gh,
        site: workGh,
        remember: true,
        existing: [pref(DomainClaim.exactHost('gitlab.com'), 'lab')],
      );
      expect(pick.preferences, [
        pref(DomainClaim.exactHost('gitlab.com'), 'lab'),
        pref(DomainClaim.exactHost('github.com'), 'work-gh'),
        pref(DomainClaim.wildcardSubdomain('github.com'), 'work-gh'),
      ]);
      expect(pick.action.siteId, 'work-gh');
      expect(pick.action.url, gh.toString());
      expect(pick.action.sourceIsParent, isTrue);
    });

    test('an unticked box, or claims already held, change nothing', () {
      expect(
        LinkIntentDispatchEngine.pickOutbound(
          url: gh,
          site: workGh,
          remember: false,
          existing: const [],
        ).preferences,
        isNull,
      );
      final held = [
        pref(DomainClaim.exactHost('github.com'), 'personal-gh'),
        pref(DomainClaim.wildcardSubdomain('github.com'), 'personal-gh'),
      ];
      final pick = LinkIntentDispatchEngine.pickOutbound(
        url: gh,
        site: workGh,
        remember: true,
        existing: held,
      );
      expect(pick.preferences, isNull);
      expect(pick.action.siteId, 'work-gh');
    });
  });

  group('LIR-016 preferencesToRemember', () {
    test('adds one entry per claim of the URL', () {
      final added = LinkIntentDispatchEngine.preferencesToRemember(
        url: Uri.parse('https://github.com/x'),
        targetSiteId: 'work-gh',
        existing: const [],
      );
      expect(added, [
        pref(DomainClaim.exactHost('github.com'), 'work-gh'),
        pref(DomainClaim.wildcardSubdomain('github.com'), 'work-gh'),
      ]);
    });

    test('skips a claim already held, whatever its target', () {
      final added = LinkIntentDispatchEngine.preferencesToRemember(
        url: Uri.parse('https://github.com/x'),
        targetSiteId: 'work-gh',
        existing: [
          pref(DomainClaim.wildcardSubdomain('github.com'), 'personal-gh'),
        ],
      );
      expect(added, [pref(DomainClaim.exactHost('github.com'), 'work-gh')]);
    });

    test('a port-bearing URL yields its one exact claim', () {
      final added = LinkIntentDispatchEngine.preferencesToRemember(
        url: Uri.parse('http://localhost:8080/x'),
        targetSiteId: 'local',
        existing: const [],
      );
      expect(added, [pref(DomainClaim.exactHost('localhost:8080'), 'local')]);
    });
  });

  group('hadGesture on navigation decisions', () {
    final now = DateTime(2026, 1, 1, 12);

    NavigationDecisionResult tap({
      required bool hasGesture,
      DateTime? lastGesture,
    }) =>
        NavigationDecisionEngine.decideShouldOverrideUrlLoading(
          targetUrl: 'https://github.com/x',
          initUrl: 'https://duckduckgo.com/',
          hasGesture: hasGesture,
          blockAutoRedirects: false,
          isSiteActive: true,
          lastSameDomainGestureTime: lastGesture,
          now: now,
        );

    test('a direct gesture is reported', () {
      final r = tap(hasGesture: true);
      expect(r.decision, NavigationDecision.blockOpenNested);
      expect(r.hadGesture, isTrue);
    });

    test('a gesture propagated inside the window is reported', () {
      final r = tap(
          hasGesture: false,
          lastGesture: now.subtract(const Duration(seconds: 3)));
      expect(r.hadGesture, isTrue);
    });

    test('no gesture, or one outside the window, is not', () {
      expect(tap(hasGesture: false).hadGesture, isFalse);
      expect(
          tap(
                  hasGesture: false,
                  lastGesture: now.subtract(const Duration(seconds: 30)))
              .hadGesture,
          isFalse);
    });

    test('the onUrlChanged path carries it through', () {
      OnUrlChangedHandled redirect(DateTime? lastGesture) =>
          NavigationDecisionEngine.handleOnUrlChanged(
            newUrl: 'https://github.com/x',
            initUrl: 'https://duckduckgo.com/',
            blockAutoRedirects: false,
            isSiteActive: true,
            lastSameDomainGestureTime: lastGesture,
            now: now,
            isCaptchaChallenge: (_) => false,
            state: OnUrlChangedState.initial('https://duckduckgo.com/'),
          );
      final withGesture =
          redirect(now.subtract(const Duration(seconds: 2)));
      expect(withGesture.launchNestedUrl, 'https://github.com/x');
      expect(withGesture.hadGesture, isTrue);
      expect(redirect(null).hadGesture, isFalse);
    });
  });

  group('LIR-013 model fields', () {
    test('legacy JSON loads with defaults and writes neither field', () {
      final m = WebViewModel.fromJson(
          WebViewModel(initUrl: 'https://duckduckgo.com/').toJson(), null);
      expect(m.routeOutboundLinks, isFalse);
      expect(m.outboundPreferences, isEmpty);
      expect(m.toJson().containsKey('routeOutboundLinks'), isFalse);
      expect(m.toJson().containsKey('outboundPreferences'), isFalse);
    });

    test('both fields round-trip', () {
      final m = WebViewModel(
        initUrl: 'https://duckduckgo.com/',
        routeOutboundLinks: true,
        outboundPreferences: [
          pref(DomainClaim.exactHost('github.com'), 'work-gh'),
          pref(DomainClaim.wildcardSubdomain('github.com'), 'work-gh'),
        ],
      );
      final back = WebViewModel.fromJson(m.toJson(), null);
      expect(back.routeOutboundLinks, isTrue);
      expect(back.outboundPreferences, m.outboundPreferences);
    });

    test('odd entries are dropped, a repeated claim keeps its first target',
        () {
      final json = WebViewModel(initUrl: 'https://duckduckgo.com/').toJson()
        ..['routeOutboundLinks'] = 'yes'
        ..['outboundPreferences'] = [
          {
            'claim': {'kind': 'exactHost', 'value': 'github.com'},
            'targetSiteId': 'work-gh',
          },
          {
            'claim': {'kind': 'exactHost', 'value': 'github.com'},
            'targetSiteId': 'personal-gh',
          },
          {'claim': {'kind': 'nonsense', 'value': 'x.org'}, 'targetSiteId': 'a'},
          {'claim': {'kind': 'exactHost', 'value': 'y.org'}},
          42,
        ];
      final m = WebViewModel.fromJson(json, null);
      expect(m.routeOutboundLinks, isFalse);
      expect(m.outboundPreferences,
          [pref(DomainClaim.exactHost('github.com'), 'work-gh')]);
    });
  });

  group('LIR-017 OutboundPreferenceGc', () {
    test('drops entries whose target is not a candidate, keeps the rest', () {
      final prefs = [
        pref(DomainClaim.exactHost('github.com'), 'work-gh'),
        pref(DomainClaim.exactHost('gitlab.com'), 'gone'),
      ];
      final next =
          OutboundPreferenceGc.pruned(prefs, (id) => id != 'gone');
      expect(next, [prefs.first]);
      expect(OutboundPreferenceGc.pruned(prefs, (_) => true), isNull);
    });

    test('pruneAll reports a change only when a list changed', () {
      final a = WebViewModel(
        initUrl: 'https://duckduckgo.com/',
        outboundPreferences: [
          pref(DomainClaim.exactHost('github.com'), 'work-gh'),
        ],
      );
      final b = WebViewModel(initUrl: 'https://example.org/');
      bool prune(Set<String> live) => OutboundPreferenceGc.pruneAll(
            [a, b],
            prefsOf: (m) => m.outboundPreferences,
            setPrefs: (m, p) => m.outboundPreferences = p,
            isCandidate: (_, id) => live.contains(id),
          );
      expect(prune({'work-gh'}), isFalse);
      expect(a.outboundPreferences, hasLength(1));
      expect(prune(const {}), isTrue);
      expect(a.outboundPreferences, isEmpty);
    });

    test('candidates stay on the source side of the archive boundary', () {
      final app1 = WebViewModel(siteId: 'app1', initUrl: 'https://a.test');
      final app2 = WebViewModel(siteId: 'app2', initUrl: 'https://b.test');
      final x1 = WebViewModel(
          siteId: 'x1', initUrl: 'https://x.test', isArchiveTier: true);
      final x2 = WebViewModel(
          siteId: 'x2', initUrl: 'https://y.test', isArchiveTier: true);
      final y1 = WebViewModel(
          siteId: 'y1', initUrl: 'https://z.test', isArchiveTier: true);
      final lost = WebViewModel(
          siteId: 'lost', initUrl: 'https://w.test', isArchiveTier: true);
      final archives = {'x1': 'X', 'x2': 'X', 'y1': 'Y'};
      final all = [app1, x1, app2, x2, y1, lost];
      List<String> of(WebViewModel source) => OutboundBoundary.candidatesOf(
            source,
            all,
            isArchiveTier: (m) => m.isArchiveTier,
            archiveOf: (m) => archives[m.siteId],
          ).map((m) => m.siteId).toList();
      expect(of(app1), ['app1', 'app2']);
      expect(of(x1), ['x1', 'x2']);
      expect(of(y1), ['y1']);
      expect(of(lost), isEmpty);
    });

    test('an import keeps only preferences naming a restored site', () {
      final backup = SettingsBackup(
        version: 1,
        sites: [
          {
            'siteId': 'ddg',
            'initUrl': 'https://duckduckgo.com/',
            'routeOutboundLinks': true,
            'outboundPreferences': [
              {
                'claim': {'kind': 'exactHost', 'value': 'github.com'},
                'targetSiteId': 'gh',
              },
              {
                'claim': {'kind': 'exactHost', 'value': 'gitlab.com'},
                'targetSiteId': 'not-in-backup',
              },
            ],
          },
          {'siteId': 'gh', 'initUrl': 'https://github.com/'},
        ],
        webspaces: const [],
        themeMode: 0,
        exportedAt: DateTime(2026),
      );
      final plan = planSettingsImport(backup);
      final ddg = plan.sites.firstWhere((s) => s.siteId == 'ddg');
      expect(ddg.routeOutboundLinks, isTrue);
      expect(ddg.outboundPreferences, [
        pref(DomainClaim.exactHost('github.com'), 'gh'),
      ]);
    });
  });
}
