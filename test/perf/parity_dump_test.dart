// Dumps every decision the blockers make over a fixed corpus, so two builds
// (or two code paths in one build) can be diffed decision by decision.
//
//   WS_PERF_DATA=<lists> WS_PARITY_OUT=<dir> fvm flutter test test/perf/parity_dump_test.dart
//
// The corpus comes from the raw list text and a fixed seed, never from the
// code under test, so a checkout of any version builds the same one. Files
// written: content_blocker_<launch>.jsonl, one per launch in [_launches] over
// one disk, so every input an engine cache could miss is changed between two
// of them; engine_parsed.jsonl and _hydrated.jsonl (one engine parsed from
// text and the same engine serialized and loaded back, the two ways Android's
// interceptor has built its own); and dns.jsonl.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/filter_list_mask.dart';
import 'package:webspace/services/filter_list_preparser.dart';
import 'package:webspace/services/procedural_action_backfill.dart';

import 'blocker_disk.dart';

final String? _outDir = Platform.environment['WS_PARITY_OUT'];

const _types = ['document', 'subdocument', 'stylesheet', 'script', 'image', 'font', 'media', 'xhr', 'other'];

const _commonHosts = [
  'discord.com',
  'cdn.discordapp.com',
  'media.discordapp.net',
  'google.com',
  'www.google.com',
  'youtube.com',
  'www.youtube.com',
  'i.ytimg.com',
  'github.com',
  'news.ycombinator.com',
  'reddit.com',
  'www.reddit.com',
  'twitter.com',
  'x.com',
  'facebook.com',
  'instagram.com',
  'wikipedia.org',
  'en.wikipedia.org',
  'amazon.com',
  'cnn.com',
  'bbc.co.uk',
  'nytimes.com',
  'theguardian.com',
  'stackoverflow.com',
  'cdn.jsdelivr.net',
  'fonts.googleapis.com',
  'ajax.googleapis.com',
  'cdnjs.cloudflare.com',
  'mail.google.com',
  'web.whatsapp.com',
];

/// An inline list with what the downloaded ones barely carry: redirects,
/// CSP, removeparam, exceptions against important, scriptlets, procedurals.
const _extras = '''
||parity-redirect.example^\$script,redirect=noopjs
||parity-redirect.example/pixel.gif\$image,redirect=1x1.gif
||parity-csp.example^\$csp=script-src 'none'
\$removeparam=utm_source
||parity-removeparam.example^\$removeparam=ref
@@||parity-allow.example^\$script
||parity-allow.example^
||parity-important.example^\$important
@@||parity-important.example^
||parity-third.example^\$third-party
/parity-path-token/\$script
example.com##.parity-hidden
example.com#?#div:has(> .parity-procedural)
example.com##+js(set-constant, parityFlag, true)
##.parity-generic-class
###parity-generic-id
example.com#@#.parity-generic-class
''';

const _extrasEdited = '''
||parity-redirect.example^\$script,redirect=noopjs
@@||parity-allow.example^
||parity-allow.example^
example.com##.parity-hidden-edited
''';

const _typeOptions = {
  'script': 'script',
  'image': 'image',
  'stylesheet': 'stylesheet',
  'font': 'font',
  'media': 'media',
  'xmlhttprequest': 'xhr',
  'subdocument': 'subdocument',
  'document': 'document',
  'other': 'other',
};

/// What the corpus is built from: the raw lists, never the parsed rules.
class _Corpus {
  _Corpus(Map<String, String> lists) {
    final rng = Random(693);
    final blockHosts = <String>[];
    final pathFragments = <String>[];
    final domainOptionHosts = <String>{};
    final classes = <String>{};
    final ids = <String>{};
    final hostRule = RegExp(r'^\|\|([a-z0-9.-]+\.[a-z]{2,})\^');
    final pathRule = RegExp(r'^/?([a-zA-Z0-9_./-]{4,40})[/^.?]');
    final domainOpt = RegExp(r'domain=([^,]+)');
    final classRule = RegExp(r'^##\.([A-Za-z0-9_-]{2,40})$');
    final idRule = RegExp(r'^###([A-Za-z0-9_-]{2,40})$');
    final cosmeticDomains = RegExp(r'^([a-z0-9.,~-]+)#[@?$]?#');
    final specialRule = RegExp(r'(^@@|[$,](redirect(-rule)?=|csp=|removeparam|important|third-party))');
    final cosmeticHosts = <String>{};
    final special = <String>[];
    for (final text in [...lists.values, _extras, _extrasEdited]) {
      for (final line in const LineSplitter().convert(text)) {
        if (line.isEmpty || line.startsWith('!') || line.startsWith('[')) continue;
        final h = hostRule.firstMatch(line);
        if (h != null) blockHosts.add(h.group(1)!);
        if (!line.startsWith('||') && !line.contains('#')) {
          final p = pathRule.firstMatch(line);
          if (p != null) pathFragments.add(p.group(1)!);
        }
        for (final m in domainOpt.allMatches(line)) {
          for (final d in m.group(1)!.split('|')) {
            final host = d.replaceFirst('~', '');
            if (RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(host)) domainOptionHosts.add(host);
          }
        }
        final c = classRule.firstMatch(line);
        if (c != null) classes.add(c.group(1)!);
        final i = idRule.firstMatch(line);
        if (i != null) ids.add(i.group(1)!);
        final cosmetic = cosmeticDomains.firstMatch(line);
        if (cosmetic != null) {
          for (final d in cosmetic.group(1)!.split(',')) {
            final host = d.replaceFirst('~', '');
            if (RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(host)) cosmeticHosts.add(host);
          }
        }
        if (specialRule.hasMatch(line)) special.add(line);
      }
    }
    T pick<T>(List<T> from) => from[rng.nextInt(from.length)];
    String word() => String.fromCharCodes(List.generate(3 + rng.nextInt(8), (_) => 97 + rng.nextInt(26)));

    final domainHosts = domainOptionHosts.toList()..sort();
    final cosmeticHostList = cosmeticHosts.toList()..sort();
    pages = [
      for (final h in _commonHosts) 'https://$h/',
      'https://example.com/',
      'https://sub.example.com/',
      for (var n = 0; n < 120; n++) 'https://${pick(domainHosts)}/${word()}',
      for (var n = 0; n < 120; n++) 'https://${pick(cosmeticHostList)}/${word()}',
    ];
    final hosts = <String>[
      for (var n = 0; n < 3000; n++) pick(blockHosts),
      for (var n = 0; n < 1500; n++) '${word()}.${pick(blockHosts)}',
      for (var n = 0; n < 1500; n++) pick(_commonHosts),
      for (var n = 0; n < 1000; n++) '${word()}.${word()}.com',
    ];
    requestHosts = hosts.toSet().toList()..sort();
    queries = [
      for (var n = 0; n < 24000; n++)
        (
          url:
              'https://${pick(hosts)}/'
              '${rng.nextBool() ? pick(pathFragments) : word()}'
              '${rng.nextInt(4) == 0 ? '?utm_source=${word()}&fbclid=${word()}&id=${rng.nextInt(999)}' : ''}',
          source: pick(pages),
          type: pick(_types),
        ),
    ];
    // Each special rule (redirect, CSP, removeparam, exception, important,
    // third-party) aimed at from its own host, with and without its type and
    // from its domain= page and from elsewhere, so the rare paths are taken.
    special.sort();
    for (final line in special) {
      final m = RegExp(r'^(?:@@)?\|\|([a-z0-9.-]+\.[a-z]{2,})([^\$^]*)').firstMatch(line);
      final host = m?.group(1) ?? pick(blockHosts);
      final path = (m?.group(2) ?? '/${word()}').replaceAll('*', 'x');
      final options = line.contains(r'$') ? line.substring(line.lastIndexOf(r'$') + 1) : '';
      final types = {
        for (final o in options.split(',')) ?_typeOptions[o],
        if (options.contains('csp=')) ...['document', 'subdocument'],
      };
      final domain = RegExp(r'domain=([a-z0-9.-]+)').firstMatch(options)?.group(1);
      for (final type in {...types, pick(_types)}) {
        for (final source in {if (domain != null) 'https://$domain/', 'https://$host/', pick(pages)}) {
          queries.add((
            url:
                'https://$host${path.startsWith('/') ? path : '/$path'}'
                '?utm_source=${word()}&ref=${word()}&keep=1',
            source: source,
            type: type,
          ));
        }
      }
    }
    final classList = classes.toList()..sort();
    final idList = ids.toList()..sort();
    scanClasses = {for (var n = 0; n < 400; n++) pick(classList), for (var n = 0; n < 100; n++) word()};
    scanIds = {for (var n = 0; n < 150; n++) pick(idList), for (var n = 0; n < 50; n++) word()};
  }

  late final List<String> pages;
  late final List<String> requestHosts;
  late final List<({String url, String source, String type})> queries;
  late final Set<String> scanClasses;
  late final Set<String> scanIds;
}

/// One app launch over the disk the previous one left: what changed on disk
/// before it, and the preferences it starts with. Each changes one input the
/// engine is built from, then launches again unchanged, so a cache that
/// answered for the wrong inputs shows as a decision the other build lacks.
typedef _Launch = ({
  String name,
  Future<void> Function(FileStore store)? disk,
  bool ubo,
  Set<String> disabled,
  Map<String, List<String>> masks,
  String? inline,
});

Future<void> _appendRule(FileStore store) async {
  final body = await store.readText('easylist.txt');
  await store.writeText('easylist.txt', contents: '$body\n||parity-update.example^\n');
}

const _masks = {
  'easylist': ['www.reddit.com', 'cnn.com'],
  'easyprivacy': ['github.com'],
};
const _edited = {
  'easylist': ['www.reddit.com'],
};

final List<_Launch> _launches = [
  (name: 'cold', disk: null, ubo: true, disabled: {}, masks: {}, inline: null),
  (name: 'warm', disk: null, ubo: true, disabled: {}, masks: {}, inline: null),
  (name: 'noubo', disk: null, ubo: false, disabled: {}, masks: {}, inline: null),
  (name: 'noubo_warm', disk: null, ubo: false, disabled: {}, masks: {}, inline: null),
  (name: 'updated', disk: _appendRule, ubo: true, disabled: {}, masks: {}, inline: null),
  (name: 'updated_warm', disk: null, ubo: true, disabled: {}, masks: {}, inline: null),
  (name: 'masked', disk: null, ubo: true, disabled: {}, masks: _masks, inline: null),
  (name: 'masked_warm', disk: null, ubo: true, disabled: {}, masks: _masks, inline: null),
  (name: 'mask_edited', disk: null, ubo: true, disabled: {}, masks: _edited, inline: null),
  (name: 'inline', disk: null, ubo: true, disabled: {}, masks: {}, inline: _extras),
  (name: 'inline_warm', disk: null, ubo: true, disabled: {}, masks: {}, inline: _extras),
  (name: 'inline_edited', disk: null, ubo: true, disabled: {}, masks: {}, inline: _extrasEdited),
  (name: 'disabled', disk: null, ubo: true, disabled: {'fanboy-annoyance'}, masks: {}, inline: _extrasEdited),
  (
    name: 'disabled_warm',
    disk: null,
    ubo: true,
    disabled: {'fanboy-annoyance'},
    masks: {},
    inline: _extrasEdited,
  ),
  (name: 'back', disk: null, ubo: true, disabled: {}, masks: {}, inline: null),
];

List<String> _sorted(Iterable<String> v) => v.toList()..sort();

Future<void> _write(String name, {required Iterable<Object?> rows}) async {
  final file = File('$_outDir/$name');
  final sink = file.openWrite();
  for (final r in rows) {
    sink.writeln(jsonEncode(r));
  }
  await sink.close();
  // ignore: avoid_print
  print('wrote ${file.path}');
}

Iterable<Object?> _serviceRows(ContentBlockerService s, {required _Corpus c}) sync* {
  yield {
    'prefilterHosts': _sorted(s.abpNetworkBlockHosts),
    'untokenizable': s.hasUntokenizableNetworkRules,
    'tokenBloom': s.genericNetworkTokenBloom?.toMap(),
  };
  for (final q in c.queries) {
    yield [
      q.url,
      q.source,
      q.type,
      s.isBlocked(q.url, sourceUrl: q.source, requestType: q.type),
      s.redirectFor(q.url, sourceUrl: q.source, requestType: q.type),
      s.cspFor(q.url, sourceUrl: q.source, requestType: q.type),
      s.rewrittenUrl(q.url, sourceUrl: q.source, requestType: q.type),
    ];
  }
  for (final h in c.requestHosts) {
    yield ['host', h, s.isHostBlocked(h)];
  }
  for (final p in c.pages) {
    yield [
      'page',
      p,
      s.getEarlyCssScript(p),
      s.getCosmeticScript(p),
      s.proceduralActionsFor(p),
      _sorted(s.genericCosmeticSelectorsFor(pageUrl: p, classes: c.scanClasses, ids: c.scanIds)),
    ];
  }
}

Iterable<Object?> _engineRows(AdblockEngine e, {required _Corpus c}) sync* {
  for (final q in c.queries) {
    yield [
      q.url,
      q.source,
      q.type,
      e.shouldBlock(q.url, sourceUrl: q.source, requestType: q.type),
      e.redirectFor(q.url, sourceUrl: q.source, requestType: q.type),
      e.cspFor(q.url, sourceUrl: q.source, requestType: q.type),
      e.rewrittenUrl(q.url, sourceUrl: q.source, requestType: q.type),
    ];
  }
  for (final p in c.pages) {
    yield ['page', p, e.cosmeticResources(p)];
    yield [
      'generic',
      p,
      _sorted(e.hiddenClassIdSelectors(c.scanClasses, ids: c.scanIds, exceptions: const {})),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = perfDataDir == null || _outDir == null ? 'set WS_PERF_DATA and WS_PARITY_OUT' : false;
  setUpAll(mockAppBuild);

  test(
    'content blocker decisions over a run of launches',
    () async {
      final lists = {for (final id in filterListIds) id: readPerfData('$id.txt')};
      final corpus = _Corpus(lists);
      final store = MemoryFileStore();
      for (final MapEntry(key: id, value: body) in lists.entries) {
        await store.writeText('$id.txt', contents: body);
      }
      final service = ContentBlockerService.instance;
      for (final launch in _launches) {
        await launch.disk?.call(store);
        SharedPreferences.setMockInitialValues({
          'content_blocker_lists': jsonEncode([
            for (final id in filterListIds)
              {
                'id': id,
                'name': id,
                'url': 'https://easylist.to/easylist/$id.txt',
                'enabled': !launch.disabled.contains(id),
              },
            if (launch.inline != null)
              {'id': 'parity-extras', 'name': 'extras', 'url': '', 'enabled': true, 'rules': launch.inline},
          ]),
          'useUboResources': launch.ubo,
          if (launch.masks.isNotEmpty) 'content_blocker_list_masks': jsonEncode(launch.masks),
        });
        service
          ..reset()
          ..store = store;
        final sw = Stopwatch()..start();
        await service.initialize();
        // ignore: avoid_print
        print('${launch.name}: initialize ${sw.elapsedMilliseconds} ms');
        expect(service.hasRules, isTrue);
        await _write('content_blocker_${launch.name}.jsonl', rows: _serviceRows(service, c: corpus));
        // The first launch writes its cache behind initialize.
        await pumpEventQueue();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'engine parsed from text vs the same engine serialized and loaded',
    () async {
      final lists = {for (final id in filterListIds) id: readPerfData('$id.txt')};
      final corpus = _Corpus(lists);
      final env = preparserEnv(android: true, ios: false, macos: false, linux: false);
      final buf = StringBuffer();
      for (final id in filterListIds) {
        buf.writeln(scopeRulesAwayFromHosts(pruneFilterList(lists[id]!, env: env), hosts: const {}));
      }
      final rules = rewriteGenericProceduralsForBackfill(buf.toString());
      final parsed = AdblockEngine.load(rules)!;
      final hydrated = AdblockEngine.loadFromSerialized(parsed.serialize()!)!;
      await _write('engine_parsed.jsonl', rows: _engineRows(parsed, c: corpus));
      await _write('engine_hydrated.jsonl', rows: _engineRows(hydrated, c: corpus));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'dns decisions',
    () async {
      final lists = {for (final id in filterListIds) id: readPerfData('$id.txt')};
      final corpus = _Corpus(lists);
      final rows = <Object?>[];
      final dns = DnsBlockService.instance;
      for (final levels in [
        [3],
        [1, 3, 5],
        [2, 4],
      ]) {
        dns.resetForTest();
        dns.loadLevelsFromStrings({
          for (final l in levels) l: readPerfData('hagezi-${dnsLevelFiles[l]}.txt'),
        });
        final stored = dns.serializeLevelSetsForTest();
        final store = MemoryFileStore();
        await store.writeText('dns_blocklist_levels.txt', contents: stored);
        SharedPreferences.setMockInitialValues({'dns_block_level': levels.last});
        dns
          ..resetForTest()
          ..store = store;
        await dns.initialize();
        final dnsHosts = <String>{
          ...corpus.requestHosts,
          for (final l in levels)
            ...const LineSplitter()
                .convert(readPerfData('hagezi-${dnsLevelFiles[l]}.txt'))
                .where((d) => d.isNotEmpty && !d.startsWith('#'))
                .take(4000),
        };
        rows.add({'levels': levels, 'domainCount': dns.domainCount});
        for (final h in _sorted(dnsHosts)) {
          rows.add([
            levels.join(','),
            h,
            dns.hostLevelMask(h),
            for (var l = 1; l <= 5; l++) dns.isHostBlockedAtLevel(h, level: l),
          ]);
        }
      }
      await _write('dns.jsonl', rows: rows);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
