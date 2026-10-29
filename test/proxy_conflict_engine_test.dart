import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/settings/proxy_ids.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/proxy_library.dart';

UserProxySettings _default() => UserProxySettings(type: ProxyType.DEFAULT);
UserProxySettings _socks(String addr, {String? user, String? pwd}) =>
    UserProxySettings(
      type: ProxyType.SOCKS5,
      address: addr,
      username: user,
      password: pwd,
    );
UserProxySettings _http(String addr) =>
    UserProxySettings(type: ProxyType.HTTP, address: addr);

void main() {
  group('fingerprint', () {
    test('all DEFAULT proxies share the same fingerprint regardless of'
        ' stale address fields', () {
      final a = _default();
      final b = UserProxySettings(
          type: ProxyType.DEFAULT, address: 'leftover:1080');
      expect(ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(a)),
          ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(b)));
    });

    test('different proxy types differ', () {
      expect(
        ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_socks('localhost:9050'))),
        isNot(ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_http('localhost:9050')))),
      );
    });

    test('same type + same address but different credentials differ', () {
      expect(
        ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_socks('a:1', user: 'u1'))),
        isNot(ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_socks('a:1', user: 'u2')))),
      );
    });

    test('two custom proxies with identical tuples are equal', () {
      expect(
        ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_socks('a:1', user: 'u', pwd: 'p'))),
        ProxyConflictEngine.fingerprint(OutboundProxy.ofApp(_socks('a:1', user: 'u', pwd: 'p'))),
      );
    });
  });

  group('canEnable / firstConflict', () {
    test('NOTIF-005-A: no other enabled sites — always true', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_socks('a:1')),
          otherEnabledProxies: const <OutboundProxy>[],
        ),
        isTrue,
      );
      expect(
        ProxyConflictEngine.firstConflict(
          targetProxy: OutboundProxy.ofApp(_socks('a:1')),
          others: const <UserProxySettings>[],
          proxyOf: OutboundProxy.ofApp,
        ),
        isNull,
      );
    });

    test('NOTIF-005-A scenario: multiple DEFAULT — toggle allowed', () {
      // Site A and Site B both DEFAULT; user enables Site C (DEFAULT).
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_default()),
          otherEnabledProxies: ([_default(), _default()]).map(OutboundProxy.ofApp),
        ),
        isTrue,
      );
    });

    test('NOTIF-005-A scenario: same custom SOCKS5 across sites — allowed',
        () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_socks('localhost:9050')),
          otherEnabledProxies: ([_socks('localhost:9050')]).map(OutboundProxy.ofApp),
        ),
        isTrue,
      );
    });

    test('NOTIF-005-A scenario: SOCKS5 conflicts with HTTP', () {
      final blocker = _socks('localhost:9050');
      final allowed = ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_http('proxy:8080')),
          otherEnabledProxies: ([blocker]).map(OutboundProxy.ofApp),
        );
      expect(allowed, isFalse);

      final conflict = ProxyConflictEngine.firstConflict(
          targetProxy: OutboundProxy.ofApp(_http('proxy:8080')),
          others: [blocker],
          proxyOf: OutboundProxy.ofApp,
        );
      expect(conflict, isNotNull);
      expect(conflict!.type, ProxyType.SOCKS5);
    });

    test('NOTIF-005-A scenario: DEFAULT target, custom blocker — blocked', () {
      // Site A enabled with custom proxy, user attempts to enable Site B
      // (DEFAULT). Effective ProxyController state would flip — block.
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_default()),
          otherEnabledProxies: ([_socks('localhost:9050')]).map(OutboundProxy.ofApp),
        ),
        isFalse,
      );
    });

    test('NOTIF-005-A scenario: same SOCKS host but mismatched credentials —'
        ' blocked', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_socks('a:1', user: 'alice')),
          otherEnabledProxies: ([_socks('a:1', user: 'bob')]).map(OutboundProxy.ofApp),
        ),
        isFalse,
      );
    });

    test('Multiple already-enabled sites, target matches all — allowed', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_socks('a:1', user: 'u', pwd: 'p')),
          otherEnabledProxies: ([
            _socks('a:1', user: 'u', pwd: 'p'),
            _socks('a:1', user: 'u', pwd: 'p'),
          ]).map(OutboundProxy.ofApp),
        ),
        isTrue,
      );
    });

    test('firstConflict returns the first mismatched entry, not the last',
        () {
      final first = _socks('a:1');
      final second = _http('b:2');
      final conflict = ProxyConflictEngine.firstConflict(
          targetProxy: OutboundProxy.ofApp(_default()),
          others: [first, second],
          proxyOf: OutboundProxy.ofApp,
        );
      expect(identical(conflict, first), isTrue);
    });
  });

  group('router mode (PROXY-013)', () {
    test('lifts the single-proxy constraint for background-poll sites', () {
      // Under the router the process-wide rule points at the loopback
      // relay permanently and each site reaches its own upstream through
      // its own credential, so two notification sites with different
      // proxies no longer contend for one slot.
      final target = UserProxySettings(
        type: ProxyType.SOCKS5,
        address: '127.0.0.1:9050',
      );
      final others = [
        UserProxySettings(type: ProxyType.HTTP, address: 'p:8080'),
        UserProxySettings(type: ProxyType.DEFAULT),
      ];

      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(target),
          otherEnabledProxies: (others).map(OutboundProxy.ofApp),
        ),
        isFalse,
        reason: 'without the router this is the PROXY-008 conflict',
      );
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(target),
          otherEnabledProxies: (others).map(OutboundProxy.ofApp),
          routesPerSite: true,
        ),
        isTrue,
      );
      expect(
        ProxyConflictEngine.firstConflict(
          targetProxy: OutboundProxy.ofApp(target),
          others: others,
          proxyOf: OutboundProxy.ofApp,
          routesPerSite: true,
        ),
        isNull,
      );
    });
  });

  // The engine used to compare the settings as configured while PROXY-008's
  // unload rule compared them resolved, so the two disagreed on which sites
  // share the process-wide override.
  group('compares the route each site takes', () {
    tearDown(() {
      GlobalOutboundProxy.resetForTest();
      ProxyLibrary.resetForTest();
    });

    test('a DEFAULT site shares the route of the proxy it inherits', () {
      GlobalOutboundProxy.setInMemory(_http('10.0.0.1:3128'));
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(_default()),
          otherEnabledProxies: ([_http('10.0.0.1:3128')]).map(OutboundProxy.ofApp),
        ),
        isTrue,
      );
    });

    test('sites naming different saved proxies conflict', () {
      ProxyLibrary.setInMemory(ProxyLibraryData(proxies: [
        SavedProxy(id: SavedProxyId('p1'), name: 'one', settings: _socks('a:1')),
        SavedProxy(id: SavedProxyId('p2'), name: 'two', settings: _socks('b:2')),
      ]));
      UserProxySettings saved(SavedProxyId id) =>
          UserProxySettings(type: ProxyType.SAVED, savedProxyId: id);
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(saved(SavedProxyId('p1'))),
          otherEnabledProxies: ([saved(SavedProxyId('p2'))]).map(OutboundProxy.ofApp),
        ),
        isFalse,
      );
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: OutboundProxy.ofApp(saved(SavedProxyId('p1'))),
          otherEnabledProxies: ([_socks('a:1')]).map(OutboundProxy.ofApp),
        ),
        isTrue,
      );
    });
  });
}
