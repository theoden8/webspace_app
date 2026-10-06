import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// LIR-032: with Site tabs on, a link into one of the user's sites opens as a
/// tab run as that site, from a site's webview and from a nested screen over
/// it. Structural, because `_WebSpacePageState` is not constructible from a
/// unit test; the decision itself is `routeToTab`, tested with the engine.
void main() {
  late String main;
  late String nested;

  setUpAll(() {
    main = File('lib/main.dart').readAsStringSync();
    nested = File('lib/screens/inappbrowser.dart').readAsStringSync();
  });

  String bodyOf(String source, String signature) {
    final start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature not found');
    return source.substring(start, source.indexOf('\n  }\n', start));
  }

  test('a nested link asks for a tab before routing does', () {
    final route = bodyOf(main, 'bool _routeOutboundLink(');
    final tab = route.indexOf('_tabRouteFor(');
    expect(tab, isNot(-1));
    expect(tab, lessThan(route.indexOf('LinkIntentDispatchEngine.routeOutbound(')));
  });

  test('the engine gets the live gates and the hosts of the owner\'s tree', () {
    final body = bodyOf(main, 'DispatchAction? _tabRouteFor(');
    for (final arg in [
      'tabsEnabled: _tabsEnabledFor(owner)',
      'containersActive: _useContainers',
      'kioskLocked: _kioskLocked',
      'hadGesture: hadGesture',
      'hosts: () => _tabHostsIn(owner, source)',
    ]) {
      expect(body, contains(arg), reason: arg);
    }
    final hosts = bodyOf(main, 'List<_SiteRouteAdapter> _tabHostsIn(');
    expect(hosts, contains('_outboundCandidates(source)'));
    expect(hosts, contains('identical(m, owner) || _mayHost(m, owner)'));
  });

  test('the source\'s routing switch decides the container (LIR-034)', () {
    final body = bodyOf(main, 'DispatchAction? _tabRouteFor(');
    expect(body,
        contains('routeOutboundLinks: source.effectiveRouteOutboundLinks'));
    // Routing off runs the tab as the source, which must be able to run in
    // the owner's tree.
    expect(body, contains('!_mayHost(source, owner)'));
  });

  test('a routed screen opens over the slot on screen, not what it runs as',
      () {
    for (final signature in [
      'Future<void> _executeOutboundDispatch(',
      'Future<void> _showOutboundPicker(',
    ]) {
      final body = bodyOf(main, signature);
      expect(body, contains('_executeOpenNested('), reason: signature);
      expect(body, isNot(contains('source: source)')), reason: signature);
      expect(body, contains('source: owner)'), reason: signature);
    }
  });

  test('a nested screen hands its link over once and closes', () {
    final start = nested.indexOf('case NavigationDecision.blockOpenNested:');
    final branch = nested.substring(start, nested.indexOf('return true;', start));
    expect(branch, contains('widget.onOpenAsTab?.call(url, result.hadGesture)'));
    expect(branch, contains('_handedOffToTab = true;'));
    expect(branch, contains('Navigator.of(context).pop();'));
    expect(nested, contains('if (_handedOffToTab) return false;'));
  });

  test('the tab opens after the screen is gone, before its opener\'s close',
      () {
    final body = bodyOf(main, 'Future<void> launchUrl(\n');
    final push = body.indexOf('await Navigator.push(');
    final run = body.indexOf('if (run != null && mounted) await run();');
    expect(push, isNot(-1));
    expect(run, greaterThan(push));
  });

  test('a screen a share opened hands nothing over', () {
    expect(main, contains('_NestedOpenHost(this, fromTab: a.sourceIsParent && source != null)'));
    expect(
      RegExp(r'launchNested\([^)]*\)\s*=>\s*state\._launchNestedForModel\(target, url, opensFromTab: fromTab\);')
          .hasMatch(main),
      isTrue,
    );
  });
}
