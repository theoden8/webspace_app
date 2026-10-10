// Times the blocker work main() awaits before runApp, on real lists.
//
//   WS_PERF_DATA=<dir> fvm flutter test test/perf/startup_bench_test.dart
//
// <dir> holds the Hagezi `hagezi-<light|multi|pro|pro.plus|ultimate>.txt`
// bodies and the EasyList family as `<list id>.txt`, as downloaded (see
// test/perf/README.md). Everything here runs on the isolate main() runs on,
// so each number is time the first frame waits for and the UI isolate is
// blocked for. A phone runs it several times slower than a desktop.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/abp_network_hosts.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/filter_list_mask.dart';
import 'package:webspace/services/filter_list_preparser.dart';
import 'package:webspace/services/procedural_action_backfill.dart';
import 'package:webspace/services/startup_init_engine.dart';

import 'blocker_disk.dart';

const _groupDnsLevel = 3;
const _runs = 5;

/// Median of [_runs] timings of [body], in ms.
Future<int> _median(Future<void> Function() body) async {
  final samples = <int>[];
  for (var i = 0; i < _runs; i++) {
    final sw = Stopwatch()..start();
    await body();
    samples.add(sw.elapsedMilliseconds);
  }
  samples.sort();
  return samples[_runs ~/ 2];
}

/// The longest the isolate went without running a timer while [body] ran:
/// on Android the UI isolate is the main thread, so this is how long input
/// and platform-channel replies would have queued.
Future<int> _longestStall(Future<void> Function() body) async {
  var longest = 0;
  final sw = Stopwatch()..start();
  var last = 0;
  final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = sw.elapsedMilliseconds;
    if (now - last > longest) longest = now - last;
    last = now;
  });
  await body();
  ticker.cancel();
  final now = sw.elapsedMilliseconds;
  return now - last > longest ? now - last : longest;
}

void _report(String label, {required int ms}) =>
    // ignore: avoid_print
    print('${label.padRight(56)} ${'$ms'.padLeft(6)} ms');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = perfDataDir == null ? 'set WS_PERF_DATA to the list directory' : false;
  setUpAll(mockAppBuild);

  group('DnsBlockService.initialize', () {
    for (final MapEntry(key: level, value: name) in dnsLevelFiles.entries) {
      test('level $level ($name)', () async {
        final dns = DnsBlockService.instance..resetForTest();
        dns.loadLevelsFromStrings({level: readPerfData('hagezi-$name.txt')});
        final disk = BlockerDisk(
          dnsLevel: level,
          dnsStored: dns.serializeLevelSetsForTest(),
          dnsCount: dns.domainCount,
        );
        final ms = await _median(() async {
          SharedPreferences.setMockInitialValues(disk.prefs);
          await disk.dnsInit();
        });
        _report('dns init, level $level (${disk.dnsCount} domains)', ms: ms);
      }, skip: skip);
    }
  });

  group('ContentBlockerService', () {
    test('steps of one engine build', () async {
      final env = preparserEnv(android: true, ios: false, macos: false, linux: false);
      final bodies = [for (final id in filterListIds) readPerfData('$id.txt')];
      late String concatenated;
      _report('prune + scope, ${bodies.length} lists', ms: await _median(() async {
        final buf = StringBuffer();
        for (final body in bodies) {
          buf.writeln(scopeRulesAwayFromHosts(pruneFilterList(body, env: env), hosts: const {}));
        }
        concatenated = buf.toString();
      }));
      _report('parseAbpNetworkPrefilter', ms: await _median(() async {
        parseAbpNetworkPrefilter(concatenated);
      }));
      late String rules;
      _report('rewriteGenericProceduralsForBackfill', ms: await _median(() async {
        rules = rewriteGenericProceduralsForBackfill(concatenated);
      }));
      _report('sha256 over the rules (${rules.length ~/ 1024} KiB)', ms: await _median(() async {
        sha256.convert(utf8.encode(rules));
      }));
      final parsed = AdblockEngine.load(rules);
      if (parsed == null) {
        markTestSkipped('no libwebspace_adblock: cargo build --release in rust/webspace_adblock');
        return;
      }
      final blob = parsed.serialize()!;
      parsed.dispose();
      _report('adblock-rust parse from text', ms: await _median(() async {
        AdblockEngine.load(rules)!.dispose();
      }));
      _report('adblock-rust deserialize (${blob.length ~/ 1024} KiB)', ms: await _median(() async {
        AdblockEngine.loadFromSerialized(blob)!.dispose();
      }));
    }, skip: skip);

    test('initialize, engine cache written by the last launch', () async {
      final disk = await BlockerDisk.seed(dnsLevel: _groupDnsLevel);
      final ms = await _median(() async {
        SharedPreferences.setMockInitialValues(disk.prefs);
        await disk.contentBlockerInit();
      });
      _report('content blocker init, warm cache', ms: ms);
    }, skip: skip);
  });

  // main() runs the inits as one concurrent group; on one isolate the CPU
  // they spend adds up however they are awaited.
  test('StartupInitEngine.runIndependentInits, both blockers', () async {
    final disk = await BlockerDisk.seed(dnsLevel: _groupDnsLevel);
    final dnsMs = await _median(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await disk.dnsInit();
    });
    final cbMs = await _median(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await disk.contentBlockerInit();
    });
    final groupMs = await _median(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await StartupInitEngine.runIndependentInits([disk.dnsInit, disk.contentBlockerInit]);
    });
    final stalls = <int>[];
    for (var i = 0; i < _runs; i++) {
      SharedPreferences.setMockInitialValues(disk.prefs);
      stalls.add(await _longestStall(() => StartupInitEngine.runIndependentInits(
          [disk.dnsInit, disk.contentBlockerInit])));
    }
    stalls.sort();
    final dnsStalls = <int>[], cbStalls = <int>[];
    for (var i = 0; i < _runs; i++) {
      SharedPreferences.setMockInitialValues(disk.prefs);
      dnsStalls.add(await _longestStall(disk.dnsInit));
      SharedPreferences.setMockInitialValues(disk.prefs);
      cbStalls.add(await _longestStall(disk.contentBlockerInit));
    }
    dnsStalls.sort();
    cbStalls.sort();
    _report('dns alone, longest UI-isolate stall', ms: dnsStalls[_runs ~/ 2]);
    _report('content blocker alone, longest UI-isolate stall', ms: cbStalls[_runs ~/ 2]);
    _report('dns alone (level $_groupDnsLevel)', ms: dnsMs);
    _report('content blocker alone', ms: cbMs);
    _report('group wall-clock (main() before runApp)', ms: groupMs);
    _report('group, longest UI-isolate stall', ms: stalls[_runs ~/ 2]);
  }, skip: skip);
}
