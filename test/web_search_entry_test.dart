import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// LIR-028 to LIR-031 and the hosted-tab plumbing it lands on (LIR-018 to LIR-024).
/// Structural, because `_WebSpacePageState` is not constructible from a unit
/// test.
void main() {
  late String main;
  late String model;

  setUpAll(() {
    main = File('lib/main.dart').readAsStringSync();
    model = File('lib/web_view_model.dart').readAsStringSync();
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
          contains('onWebSearch: () => unawaited(_webSearch()),'));
      expect(
        main,
        matches(RegExp(r'SiteMenuAction\.webSearch =>\s*'
            r'_tabsFeatureEnabled && !_tabsEnabledAt\(_currentIndex\)\s*\?')),
        reason: 'the overflow menus offer it only while tabs are off',
      );
      expect(main,
          matches(RegExp(r'case SiteMenuAction\.webSearch:\s*await _webSearch\(\);')));
    });

    test('web search is behind the Site tabs switch (LIR-029)', () {
      for (final entry in [
        'Future<void> _webSearch(',
        'Future<void> _searchFromUrlBar(',
      ]) {
        expect(firstStatement(main, entry), contains('!_tabsFeatureEnabled'),
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
      expect(firstStatement(main, 'Future<void> _webSearch('),
          contains('_kioskLocked'));
    });

    test('the sheet never loads anything itself', () {
      final body = bodyOf(main, 'Future<void> _webSearch(');
      for (final direct in ['loadUrl(', '_newTab(', '_switchActiveTab(']) {
        expect(body.contains(direct), isFalse, reason: direct);
      }
      expect(body, contains('_runSearch('));
    });

    test('the landing is the engine\'s decision', () {
      final body = bodyOf(main, 'Future<void> _runSearch(');
      expect(body, contains('WebSearchEngine.land('));
      expect(body, contains('canHost: _mayHost(searchSite, owner)'));
      expect(body, contains('_openChildTab('));
      expect(body, contains('origin: InboundOrigin.search'));
    });

    test('a results tab is a tab entry point behind the Site tabs gate', () {
      expect(firstStatement(main, 'Future<void> _openChildTab('),
          contains('!_tabsEnabled'));
    });

    test('a fallback new tab goes through the gate and New tab', () {
      final body = bodyOf(main, 'Future<void> _executeOpenInMain(');
      expect(
        RegExp(r'if \(a\.newTab && _tabsEnabledAt\(activateIndex\)\) \{\s*'
                r'await _newTab\(activateIndex, url: a\.url\);\s*return;')
            .hasMatch(body),
        isTrue,
      );
    });

    test('stale search references are pruned wherever LIR-017 prunes', () {
      expect(count(main, '_pruneOutboundPreferences();'),
          count(main, '_pruneSearchReferences();'));
    });
  });

  group('URL bar search (LIR-033)', () {
    test('the URL bar searches through the page, not on its own', () {
      final bar = bodyOf(main, 'Widget? _buildInputBar(');
      expect(bar, contains('hasUrlBar && !_kioskLocked && _tabsFeatureEnabled\n'
          '        ? _urlBarSearchFor(model)\n'
          '        : null'));
      expect(bar, contains('_searchFromUrlBar(model, query, siteId)'));
    });

    test('a URL bar search lands as a sheet search does', () {
      final body = bodyOf(main, 'Future<void> _searchFromUrlBar(');
      expect(firstStatement(main, 'Future<void> _searchFromUrlBar('),
          contains('_kioskLocked'));
      expect(body, contains('_outboundCandidates(owner).contains(site)'));
      expect(body, contains('await _runSearch(owner, site.siteId, url);'));
      expect(body, contains('await _webSearch(initialQuery: query);'));
    });

    test('the bar knows the app default without reading prefs in build', () {
      expect(bodyOf(main, 'Future<void> _pruneSearchDefaultPref('),
          contains('_webSearchDefaultSite = id'));
      expect(main, contains(
          '_webSearchDefaultSite = readPrefAs<String>(prefs, kWebSearchDefaultSiteKey);'));
    });
  });

  group('hosted tabs (LIR-018 to LIR-024)', () {
    test('only a persistent app-tier container on the container engine hosts',
        () {
      final body = bodyOf(main, 'bool _mayHost(');
      for (final rule in [
        '_useContainers',
        '!host.effectiveIncognito',
        '!host.isArchiveTier',
        '!owner.isArchiveTier',
      ]) {
        expect(body, contains(rule));
      }
    });

    test('tabs whose host is gone close at every lifecycle edge (LIR-023)', () {
      expect(count(main, 'await _closeIneligibleHostedTabs();'),
          greaterThanOrEqualTo(4),
          reason: 'startup, import, archive move, settings save');
      final delete = main.indexOf(
          'await _closeIneligibleHostedTabs(goneSiteId: deletedModel.siteId);');
      final container =
          main.indexOf('await _containerIsolation.onSiteDeleted(deletedModel.siteId);');
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
          expect(call, contains('_slotIdentities('),
              reason: '$engine at ${m.start} reads the sites, not the slots');
        }
      }
    });

    test('routing from a hosted tab uses the host as source', () {
      expect(
        bodyOf(main, 'bool _routeOutboundLink('),
        contains('final source = owner.runningIdentity;'),
      );
    });

    test('a hosted slot neither reads nor writes the HTML cache', () {
      expect(
        RegExp(r'final htmlSource = webViewModel\.runsHostedTab \|\|\s*'
                r'webViewModel\.runsForeignTab\s*\?\s*HtmlSource\.none')
            .hasMatch(main),
        isTrue,
      );
    });

    test('an owner URL never loads into a hosted slot', () {
      expect(bodyOf(main, 'Future<void> _executeOpenInMain('),
          contains('await _tabGate.runWhenIdle(() => _switchToOwnerRunTab(model));'));
      expect(count(main, '_bindOwnerRunTab('), greaterThanOrEqualTo(4));
    });

    test('the webview is built with the identity\'s container and cookies', () {
      final start = model.indexOf('  Widget getWebView(');
      final body = model.substring(
          start, model.indexOf('  WebViewController? getController('));
      expect(count(body, 'id.sitePosture(globalUserScripts: globalUserScripts)'),
          3, reason: 'the webview and both nested launches run as the identity');
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
      expect(count(body, 'returnsToOwner('), greaterThanOrEqualTo(4),
          reason: 'the tap and both redirect launches ask first');
      expect(main, contains('Future<void> _returnToOwner(WebViewModel model, String url) =>\n      _openChildTab(model, url);'));
    });
  });
}
