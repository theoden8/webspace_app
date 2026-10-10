// The blocker data a returning user's disk holds, for the startup benchmarks.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';

/// Holds the Hagezi `hagezi-<level name>.txt` bodies and the EasyList family
/// as `<list id>.txt`, as downloaded; see README.md beside this file.
final String? perfDataDir = Platform.environment['WS_PERF_DATA'];

const filterListIds = ['easylist', 'easyprivacy', 'fanboy-social', 'fanboy-annoyance'];
const dnsLevelFiles = {1: 'light', 2: 'multi', 3: 'pro', 4: 'pro.plus', 5: 'ultimate'};

String readPerfData(String name) => File('$perfDataDir/$name').readAsStringSync();

/// The engine cache is keyed by the app build.
void mockAppBuild() => PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '0.0.0',
      buildNumber: '1',
      buildSignature: '',
    );

/// What a returning user's disk holds: the DNS partition at [dnsLevel] and the
/// four filter lists with the engine cache their last launch wrote.
class BlockerDisk {
  BlockerDisk({required this.dnsLevel, required this.dnsStored, required this.dnsCount});

  final int dnsLevel;
  final String dnsStored;
  final int dnsCount;
  final MemoryFileStore lists = MemoryFileStore();

  static Future<BlockerDisk> seed({required int dnsLevel}) async {
    final dns = DnsBlockService.instance..resetForTest();
    dns.loadLevelsFromStrings({dnsLevel: readPerfData('hagezi-${dnsLevelFiles[dnsLevel]}.txt')});
    final disk = BlockerDisk(
      dnsLevel: dnsLevel,
      dnsStored: dns.serializeLevelSetsForTest(),
      dnsCount: dns.domainCount,
    );
    for (final id in filterListIds) {
      await disk.lists.writeText('$id.txt', contents: readPerfData('$id.txt'));
    }
    SharedPreferences.setMockInitialValues(disk.prefs);
    await disk.contentBlockerInit();
    return disk;
  }

  /// The preferences that turn both blockers on over this disk.
  Map<String, Object> get prefs => {
        'dns_block_level': dnsLevel,
        'content_blocker_lists': jsonEncode([
          for (final id in filterListIds)
            {'id': id, 'name': id, 'url': 'https://easylist.to/easylist/$id.txt', 'enabled': true},
        ]),
      };

  Future<void> dnsInit() async {
    final store = MemoryFileStore();
    await store.writeText('dns_blocklist_levels.txt', contents: dnsStored);
    final dns = DnsBlockService.instance
      ..resetForTest()
      ..store = store;
    await dns.initialize();
    expect(dns.domainCount, dnsCount);
  }

  Future<void> contentBlockerInit() async {
    final service = ContentBlockerService.instance
      ..reset()
      ..store = lists;
    await service.initialize();
    expect(service.hasRules, isTrue, reason: 'needs libwebspace_adblock');
  }
}

