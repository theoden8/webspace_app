import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/proxy_refused.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';

ProxyRouteKey _route(String address) =>
    (type: ProxyType.HTTP, address: address, username: null, password: null);

RouteOccupant _webview(String site) =>
    (use: RouteUse.webview, site: SiteId(site));

void main() {
  final p1 = _route('p1:8080');
  final p2 = _route('p2:8080');

  test('occupants on one route share the rule', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    await rule.claim(_webview('b'), route: p1, write: () async {});
    expect(rule.inForce, p1);
    expect(rule.occupants.keys, {_webview('a'), _webview('b')});
  });

  test('the rule cannot move under an occupant on another route '
      '(PROXY-008)', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    var wrote = false;
    await expectLater(
      rule.claim(_webview('b'), route: p2, write: () async => wrote = true),
      throwsA(isA<AssertionError>()),
    );
    expect(wrote, isFalse);
    expect(rule.inForce, p1);
  });

  test('an occupant alone may move it, and one released no longer holds '
      'it', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    await rule.claim(_webview('a'), route: p2, write: () async {});
    await rule.claim(_webview('b'), route: p2, write: () async {});
    rule.release(_webview('a'));
    rule.release(_webview('b'));
    await rule.claim(_webview('c'), route: p1, write: () async {});
    expect(rule.inForce, p1);
  });

  // A webview disposed while its claim's write is out: the release lands
  // first, and the claim must not bring it back on the route it was leaving.
  test('an occupant released during its claim stays released (PROXY-008)',
      () async {
    final rule = ProcessRoute();
    final write = Completer<void>();
    final claim =
        rule.claim(_webview('a'), route: p1, write: () => write.future);
    await Future<void>.delayed(Duration.zero);
    rule.release(_webview('a'));
    write.complete();
    await claim;
    expect(rule.occupants, isEmpty);
    await rule.claim(_webview('b'), route: p2, write: () async {});
    expect(rule.inForce, p2);
  });

  // TLC found this one in formal/process_route.tla: the release lands
  // while the claim still waits for the rule's turn behind another write.
  test('an occupant released while its claim waits stays released, and the '
      'rule does not move for it (PROXY-008)', () async {
    final rule = ProcessRoute();
    final ahead = Completer<void>();
    final first =
        rule.claim(_webview('x'), route: p2, write: () => ahead.future);
    var wrote = false;
    final waiting = rule.claim(_webview('a'), route: p1,
        write: () async => wrote = true);
    await Future<void>.delayed(Duration.zero);
    rule.release(_webview('a'));
    ahead.complete();
    await first;
    await waiting;
    expect(rule.occupants.keys, {_webview('x')});
    expect(wrote, isFalse, reason: 'nothing runs on the route it asked for');
    expect(rule.inForce, p2);
  });

  test('a webview built again claims afresh; its old claim does nothing',
      () async {
    final rule = ProcessRoute();
    final ahead = Completer<void>();
    final first =
        rule.claim(_webview('x'), route: p1, write: () => ahead.future);
    final writes = <String>[];
    final old = rule.claim(_webview('a'), route: p1,
        write: () async => writes.add('old'));
    rule.release(_webview('a'));
    final again = rule.claim(_webview('a'), route: p1,
        write: () async => writes.add('again'));
    ahead.complete();
    await Future.wait([first, old, again]);
    expect(writes, ['again']);
    expect(rule.occupants.keys, {_webview('x'), _webview('a')});
  });

  test('a check released with its kind during its claim stays released',
      () async {
    final rule = ProcessRoute();
    final write = Completer<void>();
    final check = (use: RouteUse.headless, site: SiteId('w'));
    final claim = rule.claim(check, route: p1, write: () => write.future);
    await Future<void>.delayed(Duration.zero);
    rule.releaseEvery(RouteUse.headless);
    write.complete();
    await claim;
    expect(rule.occupants, isEmpty);
  });

  test('a failed write leaves no claim behind', () async {
    final rule = ProcessRoute();
    await expectLater(
      rule.claim(_webview('a'), route: p1,
          write: () async => throw const SocketException('refused')),
      throwsA(isA<SocketException>()),
    );
    expect(rule.occupants, isEmpty);
    expect(rule.inForce, isNull);
  });

  test('one write is whole before the next begins', () async {
    final rule = ProcessRoute();
    final first = Completer<void>();
    final order = <String>[];
    final a = rule.claim(_webview('a'), route: p1, write: () async {
      order.add('a starts');
      await first.future;
      order.add('a ends');
    });
    final b = rule.claim(_webview('b'), route: p1, write: () async {
      order.add('b starts');
    });
    await pumpEventQueue();
    expect(order, ['a starts']);
    first.complete();
    await Future.wait([a, b]);
    expect(order, ['a starts', 'a ends', 'b starts']);
  });

  test('a write waits for the checks leaving the rule to close', () async {
    final rule = ProcessRoute();
    final check = (use: RouteUse.headless, site: SiteId('n'));
    await rule.claim(check, route: p1, write: () async {});
    final closing = Completer<void>();
    final order = <String>[];
    final gone = rule.vacate([check], close: () async {
      await closing.future;
      order.add('closed');
    });
    final moved = rule.claim(_webview('shown'), route: p2,
        write: () async => order.add('moved'));
    await pumpEventQueue();
    expect(order, isEmpty,
        reason: 'the check still loads on p1 until it is closed');
    expect(rule.occupants.keys, {check});
    closing.complete();
    await Future.wait([gone, moved]);
    expect(order, ['closed', 'moved']);
    expect(rule.inForce, p2);
  });

  // On device the plugin keeps a disposed webview loading until it has
  // loaded about:blank, and an icon it fetched then left through the next
  // site's proxy (proxy_router_fallback_test).
  test('a webview that goes holds the rule until it loads nothing more '
      '(PROXY-008)', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    final quiet = Completer<void>();
    final order = <String>[];
    final gone = rule.leave(_webview('a'), quiet: () async {
      await quiet.future;
      order.add('quiet');
    });
    final moved = rule.claim(_webview('b'), route: p2,
        write: () async => order.add('moved'));
    await pumpEventQueue();
    expect(order, isEmpty, reason: "a may still send on p1");
    expect(rule.occupants.keys, {_webview('a')});
    quiet.complete();
    await Future.wait([gone, moved]);
    expect(order, ['quiet', 'moved']);
    expect(rule.occupants.keys, {_webview('b')});
  });

  test('a webview that goes voids the claim it had not written yet',
      () async {
    final rule = ProcessRoute();
    final slow = Completer<void>();
    final first = rule.claim(_webview('x'), route: p1,
        write: () => slow.future);
    var wrote = false;
    final pending = rule.claim(_webview('a'), route: p1,
        write: () async => wrote = true);
    final gone = rule.leave(_webview('a'), quiet: () async {});
    slow.complete();
    await Future.wait([first, pending, gone]);
    expect(wrote, isFalse, reason: 'a went before its turn');
    expect(rule.occupants.keys, {_webview('x')});
  });

  test('the app\'s return takes a check whose claim was queued before it',
      () async {
    final rule = ProcessRoute();
    final first = (use: RouteUse.headless, site: SiteId('a'));
    final late = (use: RouteUse.headless, site: SiteId('b'));
    final writing = Completer<void>();
    final a = rule.claim(first, route: p1, write: () => writing.future);
    final b = rule.claim(late, route: p1, write: () async {});
    final gone = rule.vacateEvery(RouteUse.headless, close: () async {});
    writing.complete();
    await Future.wait([a, b, gone]);
    expect(rule.occupants, isEmpty,
        reason: 'b went on the rule after the return was asked for; left '
            'there, it would refuse the next site the user opens');
    await rule.claim(_webview('shown'), route: p2, write: () async {});
    expect(rule.inForce, p2);
  });

  test('a write that fails leaves its occupant off the rule', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    await expectLater(
      rule.claim(_webview('a'), route: p2,
          write: () async => throw const ProxyRefused('relay failed')),
      throwsA(isA<ProxyRefused>()),
    );
    expect(rule.occupants, isEmpty);
    expect(rule.inForce, p1);
  });

  test('a check joins only the route in force, and a wake releases its '
      'checks at once', () async {
    final rule = ProcessRoute();
    await rule.claim(_webview('a'), route: p1, write: () async {});
    final check = (use: RouteUse.headless, site: SiteId('b'));
    rule.join(check, route: p1);
    expect(() => rule.join((use: RouteUse.headless, site: SiteId('c')),
        route: p2), throwsA(isA<AssertionError>()));
    rule.releaseEvery(RouteUse.headless);
    expect(rule.occupants.keys, {_webview('a')});
  });
}
