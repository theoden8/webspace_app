import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/proxy_conflict_engine.dart';
import 'package:webspace/settings/proxy.dart';

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
      expect(ProxyConflictEngine.fingerprint(a),
          ProxyConflictEngine.fingerprint(b));
    });

    test('different proxy types differ', () {
      expect(
        ProxyConflictEngine.fingerprint(_socks('localhost:9050')),
        isNot(ProxyConflictEngine.fingerprint(_http('localhost:9050'))),
      );
    });

    test('same type + same address but different credentials differ', () {
      expect(
        ProxyConflictEngine.fingerprint(_socks('a:1', user: 'u1')),
        isNot(ProxyConflictEngine.fingerprint(_socks('a:1', user: 'u2'))),
      );
    });

    test('two custom proxies with identical tuples are equal', () {
      expect(
        ProxyConflictEngine.fingerprint(_socks('a:1', user: 'u', pwd: 'p')),
        ProxyConflictEngine.fingerprint(_socks('a:1', user: 'u', pwd: 'p')),
      );
    });
  });

  group('canEnable / firstConflict', () {
    test('NOTIF-005-A: no other enabled sites — always true', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _socks('a:1'),
          otherEnabledProxies: const [],
        ),
        isTrue,
      );
      expect(
        ProxyConflictEngine.firstConflict(
          targetProxy: _socks('a:1'),
          otherEnabledProxies: const [],
        ),
        isNull,
      );
    });

    test('NOTIF-005-A scenario: multiple DEFAULT — toggle allowed', () {
      // Site A and Site B both DEFAULT; user enables Site C (DEFAULT).
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _default(),
          otherEnabledProxies: [_default(), _default()],
        ),
        isTrue,
      );
    });

    test('NOTIF-005-A scenario: same custom SOCKS5 across sites — allowed',
        () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _socks('localhost:9050'),
          otherEnabledProxies: [_socks('localhost:9050')],
        ),
        isTrue,
      );
    });

    test('NOTIF-005-A scenario: SOCKS5 conflicts with HTTP', () {
      final blocker = _socks('localhost:9050');
      final allowed = ProxyConflictEngine.canEnable(
        targetProxy: _http('proxy:8080'),
        otherEnabledProxies: [blocker],
      );
      expect(allowed, isFalse);

      final conflict = ProxyConflictEngine.firstConflict(
        targetProxy: _http('proxy:8080'),
        otherEnabledProxies: [blocker],
      );
      expect(conflict, isNotNull);
      expect(conflict!.type, ProxyType.SOCKS5);
    });

    test('NOTIF-005-A scenario: DEFAULT target, custom blocker — blocked', () {
      // Site A enabled with custom proxy, user attempts to enable Site B
      // (DEFAULT). Effective ProxyController state would flip — block.
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _default(),
          otherEnabledProxies: [_socks('localhost:9050')],
        ),
        isFalse,
      );
    });

    test('NOTIF-005-A scenario: same SOCKS host but mismatched credentials —'
        ' blocked', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _socks('a:1', user: 'alice'),
          otherEnabledProxies: [_socks('a:1', user: 'bob')],
        ),
        isFalse,
      );
    });

    test('Multiple already-enabled sites, target matches all — allowed', () {
      expect(
        ProxyConflictEngine.canEnable(
          targetProxy: _socks('a:1', user: 'u', pwd: 'p'),
          otherEnabledProxies: [
            _socks('a:1', user: 'u', pwd: 'p'),
            _socks('a:1', user: 'u', pwd: 'p'),
          ],
        ),
        isTrue,
      );
    });

    test('firstConflict returns the first mismatched entry, not the last',
        () {
      final first = _socks('a:1');
      final second = _http('b:2');
      final conflict = ProxyConflictEngine.firstConflict(
        targetProxy: _default(),
        otherEnabledProxies: [first, second],
      );
      expect(identical(conflict, first), isTrue);
    });
  });
}
