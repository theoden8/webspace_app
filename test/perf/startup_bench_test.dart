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
import 'perf_samples.dart';

const _groupDnsLevel = 3;

/// The longest the isolate went without running a timer while [body] ran:
/// on Android the UI isolate is the main thread, so this is how long input
/// and platform-channel replies would have queued.
Future<double> _longestStall(Future<void> Function() body) async {
  var longest = 0.0;
  final sw = Stopwatch()..start();
  var last = 0.0;
  final ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = elapsedMs(sw);
    if (now - last > longest) longest = now - last;
    last = now;
  });
  await body();
  ticker.cancel();
  final now = elapsedMs(sw);
  return now - last > longest ? now - last : longest;
}

Future<List<double>> _stalls(Future<void> Function() body,
        {required Map<String, Object> prefs}) async =>
    [
      for (var i = 0; i < perfRuns; i++)
        await () {
          SharedPreferences.setMockInitialValues(prefs);
          return _longestStall(body);
        }(),
    ];

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
        reportSamples('dns init, level $level (${disk.dnsCount} domains)',
            samples: await timeRuns(() async {
          SharedPreferences.setMockInitialValues(disk.prefs);
          await disk.dnsInit();
        }));
      }, skip: skip);
    }
  });

  group('ContentBlockerService', () {
    test('steps of one engine build', () async {
      final env = preparserEnv(android: true, ios: false, macos: false, linux: false);
      final bodies = [for (final id in filterListIds) readPerfData('$id.txt')];
      late String concatenated;
      reportSamples('prune + scope, ${bodies.length} lists', samples: await timeRuns(() async {
        final buf = StringBuffer();
        for (final body in bodies) {
          buf.writeln(scopeRulesAwayFromHosts(pruneFilterList(body, env: env), hosts: const {}));
        }
        concatenated = buf.toString();
      }));
      reportSamples('parseAbpNetworkPrefilter', samples: await timeRuns(() async {
        parseAbpNetworkPrefilter(concatenated);
      }));
      late String rules;
      reportSamples('rewriteGenericProceduralsForBackfill', samples: await timeRuns(() async {
        rules = rewriteGenericProceduralsForBackfill(concatenated);
      }));
      reportSamples('sha256 over the rules (${rules.length ~/ 1024} KiB)', samples: await timeRuns(() async {
        sha256.convert(utf8.encode(rules));
      }));
      final parsed = AdblockEngine.load(rules);
      if (parsed == null) {
        markTestSkipped('no libwebspace_adblock: cargo build --release in rust/webspace_adblock');
        return;
      }
      final blob = parsed.serialize()!;
      parsed.dispose();
      reportSamples('adblock-rust parse from text', samples: await timeRuns(() async {
        AdblockEngine.load(rules)!.dispose();
      }));
      reportSamples('adblock-rust deserialize (${blob.length ~/ 1024} KiB)', samples: await timeRuns(() async {
        AdblockEngine.loadFromSerialized(blob)!.dispose();
      }));
    }, skip: skip);

    test('initialize, engine cache written by the last launch', () async {
      final disk = await BlockerDisk.seed(dnsLevel: _groupDnsLevel);
      reportSamples('content blocker init, warm cache', samples: await timeRuns(() async {
        SharedPreferences.setMockInitialValues(disk.prefs);
        await disk.contentBlockerInit();
      }));
    }, skip: skip);
  });

  // main() runs the inits as one concurrent group; on one isolate the CPU
  // they spend adds up however they are awaited.
  test('StartupInitEngine.runIndependentInits, both blockers', () async {
    final disk = await BlockerDisk.seed(dnsLevel: _groupDnsLevel);
    reportSamples('dns alone (level $_groupDnsLevel)', samples: await timeRuns(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await disk.dnsInit();
    }));
    reportSamples('content blocker alone', samples: await timeRuns(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await disk.contentBlockerInit();
    }));
    reportSamples('group wall-clock (main() before runApp)', samples: await timeRuns(() async {
      SharedPreferences.setMockInitialValues(disk.prefs);
      await StartupInitEngine.runIndependentInits([disk.dnsInit, disk.contentBlockerInit]);
    }));
    reportSamples('dns alone, longest UI-isolate stall',
        samples: await _stalls(disk.dnsInit, prefs: disk.prefs));
    reportSamples('content blocker alone, longest UI-isolate stall',
        samples: await _stalls(disk.contentBlockerInit, prefs: disk.prefs));
    reportSamples('group, longest UI-isolate stall',
        samples: await _stalls(
            () => StartupInitEngine.runIndependentInits([disk.dnsInit, disk.contentBlockerInit]),
            prefs: disk.prefs));
  }, skip: skip);
}
