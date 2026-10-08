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
    tabs = File('lib/controllers/tabs_controller.dart').readAsStringSync();
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
      final start = body.indexOf('for (final owner in _sites.models)');
      final end = body.indexOf('if (!changed) return;');
      expect(start, isNot(-1));
      expect(end, greaterThan(start));
      final pass = body.substring(start, end);
      expect(pass, isNot(contains('await')),
          reason: 'an await between reading what a tab runs as and '
              'rewriting it lets a tab switch in between');
      expect(pass, contains('tab.hostSiteId = host;'));
      expect(pass, contains('LinkIntentDispatchEngine.linkTabRunsAs('));
    });

    test('asks the engine with the opener\'s live switch and its own pick', () {
      for (final arg in [
        'routeOutboundLinks: opener.effectiveRouteOutboundLinks',
        'containersActive: _sites.useContainers',
        'openerPrefs: opener.outboundPreferences',
        'hosts: () => _host.tabHostsIn(owner, opener: opener)',
        'current: tab.hostSiteId ?? owner.siteId',
      ]) {
        expect(body, contains(arg), reason: arg);
      }
    });

    test('a flipped tab leaves nothing of its old container behind', () {
      final flip = body.indexOf('tab.hostSiteId = host;');
      // The old key is read while the tab still runs as the old identity.
      final key = body.indexOf('dropped.add(owner.stateKeyForTab(tab.id));');
      expect(key, isNot(-1));
      expect(key, lessThan(flip));
      expect(body, contains('await navStates.removeState(key);'));
      // A pending debounced capture would write the old page's bytes after.
      final cancel = body.indexOf('_host.cancelPendingCapture(owner.siteId);');
      expect(cancel, isNot(-1));
      expect(cancel, lessThan(flip));
    });

    test('a live slot that changed identity is rebuilt as the new one', () {
      expect(body, contains('identityBefore.putIfAbsent(owner, () => owner.runningIdentity);'));
      final apply = body.indexOf(RegExp(
          r'await _applySlotIdentityChange\(model,\s*identityBefore: entry\.value\)'));
      expect(apply, isNot(-1));
      expect(body.indexOf('model.disposeWebView();'), greaterThan(apply));
      expect(body, contains('if (!_sites.models.contains(model)) continue;'),
          reason: 'a site deleted meanwhile is not rebuilt');
    });

    test('a vanished opener leaves the tab where it is', () {
      expect(
        RegExp(r'if \(opener == null\) \{[^}]*tab\.openerSiteId = null;[^}]*continue;',
                dotAll: true)
            .hasMatch(body),
        isTrue,
      );
    });

    // Which changes run it is SiteSetChange.effects (site_runtime_test).
    test('runs in the commit, before ineligible hosted tabs close', () {
      final calls =
          RegExp(r'await _tabs\.reconcileLinkTabs\(\);').allMatches(main);
      expect(calls, hasLength(1));
      final commit = bodyOf('Future<void> _commitSites(');
      expect(commit.indexOf('await _tabs.reconcileLinkTabs();'),
          lessThan(commit.indexOf('await _tabs.closeIneligibleHostedTabs();')),
          reason: 'the host a tab now runs as must still be checked');
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
      final body = bodyIn(
          File('lib/controllers/site_activation_controller.dart')
              .readAsStringSync(),
          signature: 'Future<bool> captureStateBytes(');
      final key = body.indexOf('final key = model.activeStateKey;');
      final tab = body.indexOf('final tabId = model.activeTabId;');
      final capture = body.indexOf('await model.captureNavigationState()');
      expect(key, isNot(-1));
      expect(tab, isNot(-1));
      expect(key, lessThan(capture));
      expect(tab, lessThan(capture));
      final check = body.indexOf(
          'if (model.activeTabId != tabId || model.activeStateKey != key)');
      expect(check, greaterThan(capture),
          reason: 'a capture that outlived its tab or identity is dropped');
      expect(body.indexOf('saveState(key, state: bytes)'), greaterThan(check));
      expect(body, isNot(contains('saveState(model.activeStateKey')));
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
      final body = tabsBody('Future<void> duplicateTab(');
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
        expect(body, contains('String? openerSiteId,'), reason: signature);
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
      expect(tabsBody('Future<void> switchToOwnerRunTab('),
          contains('isForeign: model.isForeignTab'));
      expect(linksBody('Future<void> _executeOpenInMain('),
          contains('model.runsHostedTab || model.runsForeignTab'));
    });

    test('Home and a tapped link use the tab\'s own anchor', () {
      expect(main, contains('model.currentUrl = model.navigationHomeUrl;'));
      final open = linksBody('Future<void> openLinkAsTapped(');
      expect(open, contains('homeUrl: model.navigationHomeUrl'));
      expect(open, contains('matchesClaim: model.navigationMatchesClaim'));
      expect(links, contains('scopeHost: getNormalizedDomain(owner.navigationHomeUrl)'));
    });
  });

  group('container colours (TAB-018)', () {
    test('only app-tier sites are counted or given one (ARCH-001)', () {
      final body = bodyOf('void _assignContainerColors(');
      expect(body, contains('if (!m.isArchiveTier) m,'));
      expect(body, contains('ContainerColorEngine.assign('));
      expect(body, contains('kContainerPaletteSize'));
    });

    test('every site has one before it is written or drawn', () {
      final commit = bodyOf('Future<void> _commitSites(');
      final assign = commit.indexOf('_assignContainerColors();');
      expect(assign, greaterThan(commit.indexOf('_sites.apply(change);')),
          reason: 'every change, startup and import included, colours the '
              'sites it brings');
      expect(assign, lessThan(commit.indexOf('_persistSites()')),
          reason: 'demo sessions, which never write, draw marks too');
    });

    test('site info shows the colour only where containers exist', () {
      expect(
        main,
        contains('containerColor: _sites.useContainers\n'),
      );
    });
  });
}
