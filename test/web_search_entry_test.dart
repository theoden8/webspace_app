import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// LIR-028 to LIR-031 and the hosted-tab plumbing it lands on (LIR-018 to LIR-024).
/// Structural, because the page and its controllers are not constructible
/// from a unit test.
void main() {
  late String main;
  late String model;
  late String tabs;
  late String links;

  setUpAll(() {
    main = File('lib/main.dart').readAsStringSync();
    model = File('lib/web_view_model.dart').readAsStringSync();
    tabs = File('lib/controllers/tabs_controller.dart').readAsStringSync();
    links = File('lib/controllers/link_controller.dart').readAsStringSync();
  });

  int count(String source, String needle) =>
      RegExp(RegExp.escape(needle)).allMatches(source).length;

  String bodyOf(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    return source.substring(start, source.indexOf('\n  }\n', start));
  }

  String firstStatement(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    final open = source.indexOf(RegExp(r'\)\s*(async\s*)?\{'), start);
    final body = source.indexOf('{', open);
    return source.substring(body + 1, source.indexOf(';', body));
  }

  group('web search (LIR-029 to LIR-031)', () {
    test('the Tabs sheet offers Web search; the menus only with tabs off', () {
      expect(bodyOf(main, 'Future<void> _presentTabsSheet('),
          contains('onWebSearch: () => unawaited(_links.webSearch()),'));
      expect(
        main,
        matches(RegExp(r'SiteMenuAction\.webSearch =>\s*'
            r'_tabs\.featureEnabled && !_tabs\.enabledAt\(_sites\.current\)\s*\?')),
        reason: 'the overflow menus offer it only while tabs are off',
      );
      expect(main,
          matches(RegExp(r'case SiteMenuAction\.webSearch:\s*await _links\.webSearch\(\);')));
    });

    test('web search is behind the Site tabs switch (LIR-029)', () {
      for (final entry in [
        'Future<void> webSearch(',
        'Future<void> searchFromUrlBar(',
      ]) {
        expect(firstStatement(links, entry), contains('!_tabs.featureEnabled'),
            reason: entry);
      }
      final settings = File('lib/screens/app_behaviour.dart').readAsStringSync();
      expect(
        RegExp(r'bool webSearchSettingsOffered\(\) =>\s*'
                r'DeveloperModeService\.instance\.enabled &&\s*'
                r'ExperimentalFeaturesService\.instance\s*'
                r'\.switchOn\(ExperimentalFeature\.siteTabs\);')
            .hasMatch(settings),
        isTrue,
        reason: 'the gate is developer mode and the Site tabs switch',
      );
      // Up to the spread's own closing bracket, at the list's indentation.
      final gate = RegExp(
              r'if \(webSearchSettingsOffered\(\)\) \.\.\.\[(.*?)\n {10}\],',
              dotAll: true)
          .firstMatch(settings);
      expect(gate, isNotNull,
          reason: 'App Settings offers search rows only behind the gate');
      expect(gate![1], contains('leading: const Icon(Icons.travel_explore)'),
          reason: 'Default search');
      expect(gate[1], contains('create: SiteSearchListDataset.new'),
          reason: 'and the site search list download (LIR-036)');
      expect('SiteSearchListDataset.new'.allMatches(settings).length, 1,
          reason: 'built in one place, behind the gate');
      for (final other in Directory('lib/screens').listSync()) {
        if (other.path.endsWith('app_behaviour.dart')) continue;
        if (other is! File || !other.path.endsWith('.dart')) continue;
        expect(other.readAsStringSync(),
            isNot(contains('SiteSearchListDataset.new')),
            reason: '${other.path} builds the site search list outside the '
                'gate');
      }
    });

    test('a locked kiosk shell has no web search (KIOSK-002)', () {
      expect(firstStatement(links, 'Future<void> webSearch('),
          contains('_host.kioskLocked'));
    });

    test('the sheet never loads anything itself', () {
      final body = bodyOf(links, 'Future<void> webSearch(');
      for (final direct in ['loadUrl(', '.newTab(', '.switchActiveTab(']) {
        expect(body.contains(direct), isFalse, reason: direct);
      }
      expect(body, contains('_runSearch('));
    });

    test('the landing is the engine\'s decision', () {
      final body = bodyOf(links, 'Future<void> _runSearch(');
      expect(body, contains('WebSearchEngine.land('));
      expect(body, contains('canHost: _tabs.mayHost(searchSite, owner)'));
      expect(body, contains('_tabs.openChildTab('));
      expect(body, contains('origin: InboundOrigin.search'));
    });

    test('a results tab is a tab entry point behind the Site tabs gate', () {
      expect(firstStatement(tabs, 'Future<void> openChildTab('),
          contains('!enabledFor(owner)'));
    });

    test('a fallback new tab goes through the gate and New tab', () {
      final body = bodyOf(links, 'Future<void> _executeOpenInMain(');
      expect(
        RegExp(r'if \(a\.newTab && _tabs\.enabledAt\(activateIndex\)\) \{\s*'
                r'await _tabs\.newTab\(activateIndex, url: a\.url\);\s*return;')
            .hasMatch(body),
        isTrue,
      );
    });

    test('stale search references are pruned wherever LIR-017 prunes', () {
      expect(count(main, '_links.pruneOutboundPreferences();'),
          count(main, '_links.pruneSearchReferences();'));
    });
  });

  group('URL bar search (LIR-033)', () {
    test('the URL bar searches through the page, not on its own', () {
      final bar = bodyOf(main, 'Widget? _buildInputBar(');
      expect(bar, contains('hasUrlBar && !_kioskLocked && _tabs.featureEnabled\n'
          '        ? _links.urlBarSearchFor(model)\n'
          '        : null'));
      expect(bar, contains('_links.searchFromUrlBar(model, query, siteId)'));
    });

    test('a URL bar search lands as a sheet search does', () {
      final body = bodyOf(links, 'Future<void> searchFromUrlBar(');
      expect(firstStatement(links, 'Future<void> searchFromUrlBar('),
          contains('_host.kioskLocked'));
      expect(body, contains('outboundCandidates(owner).contains(site)'));
      expect(body, contains('await _runSearch(owner, site.siteId, url);'));
      expect(body, contains('await webSearch(initialQuery: query);'));
    });
  });

  group('hosted tabs (LIR-018 to LIR-024)', () {
    test('only a persistent app-tier container on the container engine hosts',
        () {
      final body = bodyOf(tabs, 'bool mayHost(');
      for (final rule in [
        '_sites.useContainers',
        '!host.effectiveIncognito',
        '!host.isArchiveTier',
        '!owner.isArchiveTier',
      ]) {
        expect(body, contains(rule));
      }
    });

    test('tabs whose host is gone close at every lifecycle edge (LIR-023)', () {
      // Which changes close them is SiteSetChange.effects (site_runtime_test).
      expect(count(main, 'await _tabs.closeIneligibleHostedTabs();'), 1,
          reason: 'the commit');
      final delete = main.indexOf(
          'await _tabs.closeIneligibleHostedTabs(goneSiteId: site.siteId);');
      final container =
          main.indexOf('await _containerIsolation.onSiteDeleted(site.siteId);');
      expect(delete, isNot(-1));
      expect(delete, lessThan(container),
          reason: 'hosted tabs close before the host\'s container goes');
    });

    test('proxy and Tor engines read what each slot runs as (LIR-024)', () {
      for (final engine in [
        'indicesToUnloadForProxyMismatch(',
        'indicesToUnloadForTorExitMismatch(',
        'torExitAnchor(',
        'torExitNodesFor(',
        'torExitPinIsArchiveOnly(',
      ]) {
        for (final m in RegExp(RegExp.escape(engine)).allMatches(main)) {
          final call = main.substring(m.start, main.indexOf(');', m.start));
          expect(call, contains('_sites.slotIdentities('),
              reason: '$engine at ${m.start} reads the sites, not the slots');
        }
      }
      expect(main, contains('state._sites.slotIdentities(except: except)'),
          reason: 'the residency host hands the plan the slots');
      final plan = bodyOf(
        File('lib/services/site_unload_engine.dart').readAsStringSync(),
        'static ResidencyPlan plan(',
      );
      for (final engine in [
        'indicesToUnloadForProxyMismatch(',
        'indicesToUnloadForTorExitMismatch(',
        'torExitAnchor(',
      ]) {
        final calls = RegExp(RegExp.escape(engine)).allMatches(plan).toList();
        expect(calls, isNotEmpty, reason: 'the plan no longer calls $engine');
        for (final m in calls) {
          final call = plan.substring(m.start, plan.indexOf(')', m.start));
          expect(call, contains('host.identities('),
              reason: '$engine in the plan reads the sites, not the slots');
        }
      }
    });

    test('routing from a hosted tab uses the host as source', () {
      expect(
        bodyOf(links, 'bool routeOutbound('),
        contains('final source = owner.runningIdentity;'),
      );
    });

    test('a hosted slot neither reads nor writes the HTML cache', () {
      expect(
        RegExp(r'final htmlSource = site\.runsHostedTab \|\|\s*'
                r'site\.runsForeignTab\s*\?\s*HtmlSource\.none')
            .hasMatch(File('lib/widgets/site_webview_stack.dart')
                .readAsStringSync()),
        isTrue,
      );
    });

    test('an owner URL never loads into a hosted slot', () {
      expect(bodyOf(links, 'Future<void> _executeOpenInMain('),
          contains('await _tabs.runWhenIdle(() => _tabs.switchToOwnerRunTab(model));'));
      final shortcuts =
          File('lib/controllers/shortcut_controller.dart').readAsStringSync();
      expect(count(main, '_tabs.bindOwnerRunTab('), greaterThanOrEqualTo(2));
      expect(count(shortcuts, '_host.bindOwnerRunTab('), 2,
          reason: 'a cold launch and a confirmed reroute land at home');
    });

    test('the webview is built with the identity\'s container and cookies', () {
      final start = model.indexOf('  Widget getWebView(');
      final body = model.substring(
          start, model.indexOf('  WebViewController? getController('));
      expect(count(body, 'id.sitePosture(globalUserScripts: globalUserScripts)'),
          2, reason: 'the webview and the nested launch run as the identity');
      for (final field in [
        'posture: posture,',
        'initUrl: navHome',
        'final String navHome = navigationHomeUrl;',
        'externalLinkMode: id.effectiveExternalLinkMode',
      ]) {
        expect(body, contains(field), reason: field);
      }
      expect(body, contains('if (activeHostMissing) return'));
    });

    test('a link home from a hosted tab returns to the owner (S6)', () {
      final start = model.indexOf('  Widget getWebView(');
      final body = model.substring(
          start, model.indexOf('  WebViewController? getController('));
      expect(
          body,
          contains('if (NavigationDecisionEngine.stepFor(decision,\n'
              '              returnsToOwner: returnsToOwner(url)) ==\n'
              '          NavigationStep.returnToOwner) {'),
          reason: 'every way out, on the tap and the redirect path, asks first');
      expect(tabs, contains('Future<void> returnToOwner(WebViewModel model, String url) =>\n      openChildTab(model, url);'));
    });
  });
}
