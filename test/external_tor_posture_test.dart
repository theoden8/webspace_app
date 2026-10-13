// TOR-026: how an external tor differs from the built-in one, judged from
// what its control port says.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/external_tor_posture_engine.dart';

ExternalTorPosture _judge({
  List<String?> socksPorts = const ['9050'],
  List<String> listeners = const ['127.0.0.1:9050'],
  String? exitNodes,
  String? safeLogging,
  String socksHost = '127.0.0.1',
  int socksPort = 9050,
}) =>
    judgeExternalTor(
      ExternalTorConfig(
        socksPorts: socksPorts,
        socksListeners: listeners,
        exitNodes: exitNodes,
        safeLogging: safeLogging,
      ),
      socksHost: socksHost,
      socksPort: socksPort,
    );

List<Type> _gaps(ExternalTorPosture posture) =>
    (posture as TorPostureRead).gaps.map((g) => g.runtimeType).toList();

void main() {
  test('a stock tor service treats sites as the built-in tor does', () {
    expect(_gaps(_judge()), isEmpty);
    expect(
        _gaps(_judge(
          socksPorts: ['unix:/run/tor/socks WorldWritable', '9050'],
          listeners: ['unix:/run/tor/socks', '127.0.0.1:9050'],
        )),
        isEmpty,
        reason: "Debian's defaults-torrc");
    expect(_gaps(_judge(socksPorts: [null])), isEmpty,
        reason: 'SocksPort at its default is 9050');
  });

  test('NoIsolateSOCKSAuth puts every site on the same circuits', () {
    expect(_gaps(_judge(socksPorts: ['9050 NoIsolateSOCKSAuth'])),
        [TorSharedCircuits]);
  });

  test('destination isolation is a difference too', () {
    expect(_gaps(_judge(socksPorts: ['127.0.0.1:9050 IsolateDestAddr'])),
        [TorPerDestinationHost]);
    expect(
        _gaps(_judge(socksPorts: ['9050 IsolateDestPort IsolateDestAddr'])),
        [TorPerDestinationHost, TorPerDestinationPort]);
  });

  test('only the SocksPort sites dial is judged', () {
    expect(
        _gaps(_judge(
          socksPorts: ['9050', '9150 NoIsolateSOCKSAuth IsolateDestAddr'],
          listeners: ['127.0.0.1:9050', '127.0.0.1:9150'],
        )),
        isEmpty);
    expect(
        _gaps(_judge(
          socksPorts: ['9050', '9150 NoIsolateSOCKSAuth'],
          listeners: ['127.0.0.1:9050', '127.0.0.1:9150'],
          socksPort: 9150,
        )),
        [TorSharedCircuits]);
  });

  test('an auto port is matched when it is the only one', () {
    expect(
        _gaps(_judge(
          socksPorts: ['auto IsolateDestAddr'],
          listeners: ['127.0.0.1:41234'],
          socksPort: 41234,
        )),
        [TorPerDestinationHost]);
    expect(
        _gaps(_judge(
          socksPorts: ['auto', 'auto'],
          listeners: ['127.0.0.1:41234', '127.0.0.1:41235'],
          socksPort: 41234,
        )),
        [TorSocksFlagsUnknown]);
  });

  test('a wildcard listener serves loopback', () {
    expect(
        _gaps(_judge(
          socksPorts: ['0.0.0.0:9050'],
          listeners: ['0.0.0.0:9050'],
          socksHost: 'localhost',
        )),
        isEmpty);
  });

  test("the tor's own exits and logging", () {
    final posture = _judge(exitNodes: '{us},{ca}', safeLogging: '0')
        as TorPostureRead;
    expect(posture.gaps.whereType<TorOwnExits>().single.nodes, '{us},{ca}');
    expect(posture.gaps.whereType<TorLogsAddresses>(), hasLength(1));
    expect(_gaps(_judge(safeLogging: 'relay')), [TorLogsAddresses],
        reason: 'relay scrubs only what tor logs as a relay');
  });

  test('a control port whose tor does not listen at the address is not it',
      () {
    expect(_judge(listeners: ['127.0.0.1:9150']), isA<TorPostureOtherTor>());
    expect(_judge(listeners: const []), isA<TorPostureOtherTor>());
  });

  // Rung 5: the built-in tor's SocksPort and SafeLogging are Swift string
  // constants, and no type crosses from TorControllerPlugin.swift to Dart.
  test('the built-in posture is the one the Swift plugin configures', () {
    final swift = File('ios/Runner/TorControllerPlugin.swift').readAsStringSync();
    final socksPort = RegExp(r'static let socksPortValue = "([^"]*)"')
        .firstMatch(swift)!
        .group(1)!;
    final flags = socksPort.split(' ').skip(1).map((f) => f.toLowerCase());
    expect(
        (
          bySocksAuth: !flags.contains('noisolatesocksauth'),
          byDestAddr: flags.contains('isolatedestaddr'),
          byDestPort: flags.contains('isolatedestport'),
        ),
        kBuiltInTorIsolation);
    expect(RegExp(r'"SafeLogging": "([^"]*)"').firstMatch(swift)!.group(1),
        kBuiltInTorSafeLogging);
  });
}
