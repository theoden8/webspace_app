import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// LIR-034 and TAB-018 wiring in `_WebSpacePageState`, `TabsController` and
/// `LinkController`:
/// where link tabs pick up their opener, where a flipped routing switch moves
/// them between containers, and the races around both. Structural, because
/// the page state is not constructible from a unit test; the decisions
/// themselves are `linkTabRunsAs` and `ContainerColorEngine`, tested with the
/// engines, and the deferral is `TabHandlingGate`, tested on its own.
void main() {
  late String main;
  late String tabs;
  late String links;

  setUpAll(() {
    main = File('lib/screens/webspace_page.dart').readAsStringSync();
    tabs = [
      for (final f in ['tabs_controller', 'tab_table'])
        File('lib/controllers/$f.dart').readAsStringSync(),
    ].join('\n');
    links = File('lib/controllers/link_controller.dart').readAsStringSync();
  });

  String bodyIn(String source, {required String signature}) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    return source.substring(start, source.indexOf('\n  }\n', start));
  }

  String bodyOf(String signature) => bodyIn(main, signature: signature);
  String tabsBody(String signature) => bodyIn(tabs, signature: signature);
  String linksBody(String signature) => bodyIn(links, signature: signature);

  group('the reconcile (LIR-034)', () {
    late String body;
    setUp(() => body = tabsBody('Future<void> reconcileLinkTabs('));

    test('waits for a running tab handler instead of racing it', () {
      final deferral = body.indexOf('if (_gate.busy) {');
      expect(deferral, isNot(-1));
      expect(body.indexOf('_gate.deferUntilIdle('), greaterThan(deferral));
      expect(body.indexOf('await _gate.run('), greaterThan(deferral),
          reason: 'the gate releases in its own finally, or the deferred run '
              'never comes and every tab handler is locked out');
      expect(body, contains('if (_host.mounted) unawaited(reconcileLinkTabs());'),
          reason: 'the deferred run must not outlive the page');
    });

    test('rewrites every tab list in one pass with no await inside', () {
      final flips = body.indexOf('final flips = _linkFlips();');
      expect(flips, isNot(-1));
      final step = body.indexOf('tabInputs.runInput(c, from: TabPlace.reroute)');
      final rest = body.indexOf('commit: const Commit.unmodeled(Unmodeled.identityChange),');
      expect(step, greaterThan(flips));
      expect(rest, greaterThan(flips));
      expect(body.substring(flips, step), isNot(contains('await')),
          reason: 'an await between reading what a tab runs as and '
              'rewriting it lets a tab switch in between');
      expect(body.substring(flips, rest), isNot(contains('await navStates')));
      for (final pass in [
        tabsBody('List<LinkFlip> _linkFlips('),
        tabsBody('Map<TabId, String> _applyFlips('),
      ]) {
        expect(pass, isNot(contains('await')));
      }
      expect(tabsBody('Map<TabId, String> _applyFlips('),
          contains('SiteTab.hostCell.write(at: tab, to: host, commit: commit);'));
      expect(tabsBody('SiteId _linkRunsAs('),
          contains('LinkIntentDispatchEngine.linkTabRunsAs('));
    });

    test('asks the engine with the opener\'s live switch and its own pick', () {
      final ask = tabsBody('SiteId _linkRunsAs(');
      for (final arg in [
        'routeOutboundLinks: routes',
        'containersActive: _sites.useContainers',
        'openerPrefs: opener.outboundPreferences',
        'hosts: () => _host.tabHostsIn(owner, opener: opener)',
        'current: tab.hostSiteId ?? owner.siteId',
      ]) {
        expect(ask, contains(arg), reason: arg);
      }
      expect(tabsBody('List<LinkFlip> _linkFlips('),
          contains('routes: opener.effectiveRouteOutboundLinks'));
    });

    test('a flipped tab leaves nothing of its old container behind', () {
      final apply = tabsBody('Map<TabId, String> _applyFlips(');
      final flip = apply.indexOf('SiteTab.hostCell.write(at: tab, to: host, commit: commit);');
      // The old key is read while the tab still runs as the old identity.
      final key = apply.indexOf('dropped[tab.id] = owner.stateKeyForTab(tab.id);');
      expect(key, isNot(-1));
      expect(key, lessThan(flip));
      expect(body, contains('await navStates.removeState(key);'));
      expect(tabs, contains('_flow.from(c).dropped[_eachClosing.it.run(c)]!'),
          reason: "the reroute's removals take the keys the flips read");
      // A pending debounced capture would write the old page's bytes after.
      final cancel = apply.indexOf('_host.cancelPendingCapture(owner.siteId);');
      expect(cancel, isNot(-1));
      expect(cancel, lessThan(flip));
    });

    // What the turn does under a process-wide proxy, against taps and tab
    // switches, is the reroute world of activation_schedules_test.
    test('a live slot lets go of its webview in the turn its identity moves '
        '(LIR-024)', () {
      final apply = tabsBody('Map<TabId, String> _applyFlips(');
      expect(apply.indexOf('model.disposeWebView(commit: commit);'),
          greaterThan(apply.indexOf('SiteTab.hostCell.write(')),
          reason: 'a plan between the two would read the new identity\'s '
              'route for a webview still on the old one');
      expect(apply, contains('if (global && retire) _sites.retired(model, commit: commit);'));
    });

    test('a vanished opener leaves the tab where it is', () {
      expect(
        RegExp(r'_sites\.byId\(tab\.openerSiteId!\) != null\)[^}]*continue;\s*\}\s*'
                r'SiteTab\.openerCell\.write\(\s*at: tab,\s*to: null,',
                dotAll: true)
            .hasMatch(tabsBody('bool _forgetGoneOpeners(')),
        isTrue,
      );
    });

    // Which changes run it is SiteSetChange.effects (site_runtime_test), and
    // that it runs before ineligible hosted tabs close is
    // site_set_commit_test.
    test('runs in the commit, after the settings screen closes', () {
      final calls = RegExp(r'_tabs\.reconcileLinkTabs\(\)').allMatches(main);
      expect(calls, hasLength(1), reason: 'the commit is its one caller');
      final settings = bodyOf('Future<void> _openSiteSettings(');
      expect(
        settings.indexOf('_commitSites(const SiteSettingsClosed())'),
        greaterThan(settings.indexOf('await Navigator')),
        reason: 'after the settings screen closes, not when it opens',
      );
    });

    test('the gate is the one every tab handler holds', () {
      expect(tabs, contains('late final TabHandlingGate _gate = TabHandlingGate(scheduleMicrotask);'));
      expect(RegExp(r'\bTabHandlingGate\(').allMatches(main + tabs), hasLength(1),
          reason: 'one gate for every tab handler');
      for (final source in [main, tabs]) {
        expect(RegExp(r'\bbool _isTabHandling\b').hasMatch(source), isFalse,
            reason: 'a second flag would let the reconcile run beside a handler');
      }
    });
  });

  group('state capture across a flip', () {
    test('keys the bytes by what the tab was when the capture started', () {
      final source = File('lib/controllers/site_activation_controller.dart')
          .readAsStringSync();
      final begin = bodyIn(source, signature: 'NavCapture? beginNavCapture(');
      expect(begin, contains('t.id == model.tabBinding.built'));
      expect(begin, isNot(contains('await')),
          reason: 'the key is read before any await');
      final captureSource =
          File('lib/controllers/site_nav_capture.dart').readAsStringSync();
      final start = captureSource
          .indexOf('final class SiteNavCapture implements NavCapture {');
      expect(start, isNot(-1));
      final capture = captureSource.substring(
          start, captureSource.indexOf('\n}\n', start));
      expect(capture, contains('key = model.stateKeyForTab(tab.id)'));
      final read = capture.indexOf('await model.captureNavigationState()');
      final check = capture.indexOf(
          'model.tabs.contains(tab) && model.stateKeyForTab(tab.id) == key');
      final save = capture.indexOf('saveState(key, state: bytes)');
      expect(read, isNot(-1));
      expect(check, greaterThan(read),
          reason: 'a capture that outlived its tab or identity is dropped');
      expect(save, greaterThan(check));
      expect(capture, isNot(contains('activeStateKey')));
      final whole =
          bodyIn(source, signature: 'Future<bool> captureStateBytes(');
      final holds = whole.indexOf('capture.stillHolds()');
      expect(holds, greaterThan(whole.indexOf('await capture.read()')));
      expect(whole.indexOf('capture.save(bytes)'), greaterThan(holds));
    });
  });

  group('every link tab carries its opener (LIR-034)', () {
    test('a link routed into a tab', () {
      final body = linksBody('Future<void> executeTabRoute(');
      expect(
        RegExp(r'openerSiteId: source\.siteId,\s*homeUrl: url\.toString\(\)')
            .allMatches(body),
        hasLength(1),
      );
      final picker = linksBody('Future<void> showOutboundPicker(');
      expect(
        RegExp(r'openerSiteId: source\.siteId,\s*homeUrl: url\.toString\(\)')
            .allMatches(picker)
            .length,
        greaterThanOrEqualTo(2),
        reason: 'the picker opens a tab from a parked and an unparked source',
      );
    });

    test('a duplicate keeps it', () {
      final body = tabsBody('static SiteTab _copyOf(SiteTab source) {');
      expect(body, contains('openerSiteId: source.openerSiteId,'));
      expect(body, contains('homeUrl: source.homeUrl,'));
      expect(body, contains('hostSiteId: source.hostSiteId,'));
    });

    test('the tab builders pass it through to the record', () {
      for (final signature in [
        'Future<void> openChildTab(',
        'Future<void> openLinkInNewTab(',
      ]) {
        final body = tabsBody(signature);
        expect(body, contains('SiteId? openerSiteId,'), reason: signature);
        expect(body, contains('openerSiteId: openerSiteId,'), reason: signature);
        expect(body, contains('homeUrl: homeUrl,'), reason: signature);
      }
    });

    test('open in new tab from a link keeps the identity it runs as', () {
      expect(main, contains('openerSiteId: active.openerSiteId,'));
      expect(main, contains('homeUrl: active.homeUrl'));
      expect(main, contains('openerSiteId: identity.siteId,'));
    });
  });

  group('foreign tabs navigate by their own domain (LIR-034)', () {
    test('owner URLs move off a foreign tab first', () {
      expect(tabsBody('Future<void> bindOwnerRunTab('),
          contains('!model.runsHostedTab && !model.runsForeignTab'));
      expect(tabsBody('Future<void> _ownerRun('),
          contains('isForeign: model.isForeignTab'));
      expect(linksBody('Future<void> _executeOpenInMain('),
          contains('model.runsHostedTab || model.runsForeignTab'));
    });

    test('Home and a tapped link use the tab\'s own anchor', () {
      expect(
          File('lib/controllers/site_reset_controller.dart').readAsStringSync(),
          contains('model.currentUrl = model.navigationHomeUrl;'));
      final open = linksBody('Future<void> openLinkAsTapped(');
      expect(open, contains('homeUrl: model.navigationHomeUrl'));
      expect(open, contains('matchesClaim: model.navigationMatchesClaim'));
      expect(links, contains('scopeHost: getNormalizedDomain(owner.navigationHomeUrl)'));
    });
  });

  // Which sites get a colour and when is site_set_commit_test.
  group('container colours (TAB-018)', () {
    test('site info shows the colour only where containers exist', () {
      expect(
        File('lib/widgets/site_info_sheet.dart').readAsStringSync(),
        contains(
            'containerColor: isolation is Containers ? id.drawnContainerColor : null,'),
      );
      expect(main, contains('site: model, isolation: _sites.isolation'));
    });
  });
}
