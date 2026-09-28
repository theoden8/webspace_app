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
    test('both overflow menus offer Web search', () {
      expect(count(main, 'value: "webSearch"'), 2);
      expect(
        RegExp(r"case 'webSearch':\s*await _webSearch\(\);")
            .allMatches(main)
            .length,
        2,
      );
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
        RegExp(r'final htmlSource = webViewModel\.runsHostedTab\s*\?\s*HtmlSource\.none')
            .hasMatch(main),
        isTrue,
      );
    });

    test('an owner URL never loads into a hosted slot', () {
      expect(bodyOf(main, 'Future<void> _executeOpenInMain('),
          contains('await _switchToOwnerRunTab(model);'));
      expect(count(main, '_bindOwnerRunTab('), greaterThanOrEqualTo(4));
    });

    test('the webview is built with the identity\'s container and cookies', () {
      final start = model.indexOf('  Widget getWebView(');
      final body = model.substring(
          start, model.indexOf('  WebViewController? getController('));
      for (final field in [
        'siteId: id.siteId',
        'cookieSiteId: id.siteId',
        'proxySettings: id.outboundProxySettings',
        'userScripts: id.combineUserScripts(globalUserScripts)',
        'initUrl: id.initUrl',
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
