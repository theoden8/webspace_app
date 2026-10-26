// Counts the `blockCheck` round trips one page makes through WebKit's
// sub-resource interceptor, and times what they cost the app.
//
//   WS_PERF=1 fvm flutter test test/perf/block_check_bench_test.dart
//
// The page runs in jsdom (test/js/perf/block_check_page.js, which needs node
// and `npm ci`): the shipped interceptor, handed what the app's
// `getBlockBloom` answers, issues [_page] and reports each `blockCheck` it
// makes. Those calls then reach the app's handler as the plugin delivers
// them, a platform message on the webview's channel, so a time includes the
// plugin's decode and encode (the same Dart in its iOS, macOS and Android
// packages) but not WebKit's IPC or the platform thread, whose floor
// integration_test/js_bridge_benchmark_test.dart measures on a device. Each
// is timed on an idle isolate and on a busy one, which spends 8 ms of every
// 16 on other work, as the UI isolate does building frames while a page
// loads.
//
// Lists: test/fixtures/easylist_sample.txt; with WS_PERF_DATA, the EasyList
// family and Hagezi Pro the app downloads (README).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/web_view_model.dart';

import '../helpers/silent_hooks.dart';
import 'blocker_disk.dart';
import 'perf_samples.dart';

const _origin = 'https://www.news.example';
const _pageUrl = '$_origin/2026/10/article';
const _viewId = 'block_check_bench';
const _channel = 'com.pichillilorenzo/flutter_inappwebview_$_viewId';

typedef _Request = ({String via, String tag, String url});

_Request _parsed(String tag, {required String url}) => (via: 'parsed', tag: tag, url: url);
_Request _assigned(String tag, {required String url}) => (via: 'assigned', tag: tag, url: url);
_Request _fetch(String url) => (via: 'fetch', tag: '', url: url);
_Request _xhr(String url) => (via: 'xhr', tag: '', url: url);

/// One article: what its markup names, what its scripts add, its ads, then a
/// live-update poll and the next images as the reader scrolls. The icons, the
/// avatars of repeat commenters and the poll ask for a URL again; everything
/// else is asked for once.
final List<List<_Request>> _page = [
  [
    for (var i = 0; i < 4; i++) _parsed('link', url: '$_origin/static/css/site.$i.css'),
    _parsed('link', url: 'https://fonts.googleapis.com/css2?family=Roboto'),
    for (var i = 0; i < 5; i++) _parsed('script', url: '$_origin/static/js/app.$i.js'),
    _parsed('script', url: 'https://cdn.jsdelivr.net/npm/lit@3.1.0/index.js'),
    _parsed('script', url: 'https://www.google-analytics.com/analytics.js'),
    _parsed('script', url: 'https://securepubads.g.doubleclick.net/tag/js/gpt.js'),
    for (var i = 0; i < 24; i++) _parsed('img', url: 'https://img.news.example/photo/$i.jpg'),
    for (final icon in ['share', 'comment', 'bookmark'])
      for (var n = 0; n < 3; n++) _parsed('img', url: '$_origin/static/icons/$icon.svg'),
    _parsed('iframe', url: 'https://www.youtube.com/embed/abc123'),
  ],
  [
    for (final api in ['article/1', 'comments?article=1', 'user', 'recommend?article=1'])
      _fetch('$_origin/api/$api'),
    for (var i = 0; i < 16; i++)
      _assigned('img', url: 'https://avatars.news.example/u/${i % 12}.jpg'),
    _xhr('https://www.google-analytics.com/collect?v=1&t=pageview&cid=42'),
    _assigned('img', url: 'https://pixel.tracker.example/p.gif?e=view'),
  ],
  [
    for (var i = 0; i < 2; i++)
      _parsed('iframe',
          url: 'https://tpc.googlesyndication.com/safeframe/1-0-40/html/container.html?n=$i'),
    for (var i = 0; i < 4; i++)
      _assigned('img', url: 'https://ad.doubleclick.net/ddm/ad/n$i;ord=$i'),
    _assigned('img', url: 'https://img.news.example/ads/banner-300.gif'),
    _assigned('script', url: 'https://pathblock.example/ads/slot.js'),
  ],
  for (var n = 0; n < 5; n++) [
    _fetch('$_origin/api/live?article=1'),
    for (var i = 0; i < 4; i++)
      _assigned('img', url: 'https://img.news.example/photo/lazy-${4 * n + i}.jpg'),
    _xhr('https://www.google-analytics.com/g/collect?v=2&en=scroll&_s=${n + 2}'),
  ],
];

/// The blockers over the bench's lists, as a launch leaves them.
Future<String> _loadLists() async {
  if (perfDataDir != null) {
    final disk = await BlockerDisk.seed(dnsLevel: 3);
    await disk.dnsInit();
  } else {
    final store = MemoryFileStore();
    await store.writeText('easylist.txt',
        contents: File('test/fixtures/easylist_sample.txt').readAsStringSync());
    SharedPreferences.setMockInitialValues({
      'content_blocker_lists': jsonEncode([
        {'id': 'easylist', 'name': 'easylist', 'url': '', 'enabled': true},
      ]),
    });
    DnsBlockService.instance.resetForTest();
    ContentBlockerService.instance
      ..reset()
      ..store = store;
    await ContentBlockerService.instance.initialize();
  }
  final service = ContentBlockerService.instance;
  expect(service.hasRules, isTrue, reason: 'needs libwebspace_adblock');
  // As main() hands them over.
  DnsBlockService.instance.setAbpNetworkHosts(service.abpNetworkBlockHosts);
  return perfDataDir != null
      ? '${filterListIds.length} filter lists + Hagezi ${dnsLevelFiles[3]}'
      : 'test/fixtures/easylist_sample.txt';
}

/// A webview's channel with the app's page handlers on it, and a `noop`
/// handler beside them for the bridge's own floor.
void _registerHandlers() {
  AndroidInAppWebViewPlatform.registerWith();
  // As a release build has it: a debug one logs every handler call.
  inapp.PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  final site = WebViewModel(initUrl: _pageUrl);
  final config = WebViewConfig(
    posture: site.sitePosture(globalUserScripts: const []),
    hooks: silentHooks(),
    initialUrl: _pageUrl,
  );
  final controller = inapp.InAppWebViewController.fromPlatform(
    platform: AndroidInAppWebViewController(
        const AndroidInAppWebViewControllerCreationParams(id: _viewId)),
  );
  PageHandlers.registerPageHandlers(
    controller,
    config: config,
    userScriptService: UserScriptService(scripts: const []),
  );
  controller.addJavaScriptHandler(handlerName: 'noop', callback: (args) => false);
}

typedef _Call = ({String handler, String url});

/// [call] made by the page's top frame, as the plugin hands it to Dart.
ByteData _message(_Call call) =>
    const StandardMethodCodec().encodeMethodCall(MethodCall('onCallJsHandler', {
      'handlerName': call.handler,
      'data': {
        'args': jsonEncode([if (call.url.isNotEmpty) call.url]),
        'isMainFrame': true,
        'origin': _origin,
        'requestUrl': _pageUrl,
      },
    }));

/// What the handler answers [call], decoded as the page gets it.
Future<Object?> _ask(_Call call) {
  final done = Completer<Object?>();
  ServicesBinding.instance.channelBuffers.push(_channel, _message(call), (data) {
    final json = const StandardMethodCodec().decodeEnvelope(data!) as String;
    done.complete(jsonDecode(json));
  });
  return done.future;
}

/// Posts call i at times[i] on the monotonic clock every isolate shares, from
/// an isolate of its own, as the platform thread posts a message whatever
/// the UI isolate is doing.
void _post((SendPort, List<int>) job) {
  final (port, times) = job;
  for (var i = 0; i < times.length; i++) {
    // Sleep to within half a millisecond, then spin, so this isolate takes
    // no core from the one being measured.
    final early = times[i] - Timeline.now - 500;
    if (early > 0) sleep(Duration(microseconds: early));
    while (Timeline.now < times[i]) {
      continue;
    }
    port.send(i);
  }
}

/// Delivers [calls], each [offsets] µs from now, as platform messages on the
/// webview's channel: the ms from each one's arrival to its reply. A busy
/// isolate takes a message late, and that wait counts.
Future<List<double>> _deliver(List<_Call> calls, {required List<int> offsets}) async {
  final start = Timeline.now + 50000;
  final times = [for (final o in offsets) start + o];
  final ms = List<double>.filled(calls.length, 0);
  final replies = <Future<void>>[];
  final port = ReceivePort();
  await Isolate.spawn(_post, (port.sendPort, times));
  await for (final i in port.cast<int>()) {
    final done = Completer<void>();
    replies.add(done.future);
    ServicesBinding.instance.channelBuffers.push(_channel, _message(calls[i]), (_) {
      ms[i] = (Timeline.now - times[i]) / 1000;
      done.complete();
    });
    if (replies.length == calls.length) break;
  }
  port.close();
  await Future.wait(replies);
  return ms;
}

/// [body] while the isolate spends 8 ms of every 16 on other work.
Future<T> _busy<T>(Future<T> Function() body) async {
  final load = Timer.periodic(const Duration(milliseconds: 16), (_) {
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < 8000) {
      continue;
    }
  });
  try {
    return await body();
  } finally {
    load.cancel();
  }
}

/// The `blockCheck` calls the shipped interceptor makes for [_page], one list
/// per phase.
Future<List<List<String>>> _pageCalls({
  required Object? bloom,
  required Map<String, Object?> verdicts,
}) async {
  final dir = Directory.systemTemp.createTempSync('block_check');
  final input = File('${dir.path}/page.json')
    ..writeAsStringSync(jsonEncode({
      'pageUrl': _pageUrl,
      'bloom': bloom,
      'verdicts': verdicts,
      'phases': [
        for (final phase in _page)
          [for (final r in phase) {'via': r.via, 'tag': r.tag, 'url': r.url}],
      ],
    }));
  final run = await Process.run('node', ['test/js/perf/block_check_page.js', input.path]);
  dir.deleteSync(recursive: true);
  expect(run.exitCode, 0, reason: '${run.stderr}');
  final phases = (jsonDecode(run.stdout as String) as Map)['phases'] as List;
  return [for (final p in phases) (p as List).cast<String>()];
}

/// Calls one at a time: each arrives at a moment of its own in a 20 ms slot,
/// unrelated to when the isolate is free.
List<int> _oneAtATime(int n, {required Random rng}) =>
    [for (var i = 0; i < n; i++) i * 20000 + rng.nextInt(16000)];

/// How long the page's requests waited for their verdicts, in ms: a phase's
/// calls arrive together, and the phase waits for its last answer.
Future<double> _pageWait(List<List<String>> calls, {required Random rng}) async {
  final flat = [for (final phase in calls) for (final url in phase) (handler: 'blockCheck', url: url)];
  final offsets = <int>[];
  for (var p = 0; p < calls.length; p++) {
    final at = p * 250000 + rng.nextInt(16000);
    offsets.addAll(List.filled(calls[p].length, at));
  }
  final ms = await _deliver(flat, offsets: offsets);
  var total = 0.0;
  var i = 0;
  for (final phase in calls) {
    total += ms.sublist(i, i + phase.length).fold(0.0, max);
    i += phase.length;
  }
  return total;
}

void _say(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = Platform.environment['WS_PERF'] == null ? 'set WS_PERF=1' : false;
  setUpAll(mockAppBuild);

  test('blockCheck round trips of one page', () async {
    final lists = await _loadLists();
    _registerHandlers();
    final bloom = await _ask((handler: 'getBlockBloom', url: ''));
    final requested = {for (final phase in _page) for (final r in phase) r.url};
    final verdicts = {
      for (final url in requested) url: await _ask((handler: 'blockCheck', url: url)),
    };
    final calls = await _pageCalls(bloom: bloom, verdicts: verdicts);
    final flat = [for (final phase in calls) for (final url in phase) (handler: 'blockCheck', url: url)];
    final requests = _page.fold(0, (n, phase) => n + phase.length);
    _say('lists: $lists; genericFallback ${(bloom as Map)['genericFallback']}');
    _say('page: $requests requests, ${requested.length} distinct URLs, '
        '${flat.length} blockCheck calls (${flat.map((c) => c.url).toSet().length} distinct)');
    // What the prefilter would send were no rule untokenizable, and what the
    // host Bloom alone sends: the floor a better token prefilter could reach.
    for (final (label, without) in [
      ('without the fallback', {'genericFallback': false}),
      ('host Bloom alone', {'genericFallback': false, 'hasGeneric': false}),
    ]) {
      final asked = await _pageCalls(bloom: {...bloom, ...without}, verdicts: verdicts);
      _say('  $label: ${asked.fold(0, (n, phase) => n + phase.length)} calls');
    }

    // Warm the handler and the engine before any number is taken.
    for (var w = 0; w < 3; w++) {
      for (final call in flat) {
        await _ask(call);
      }
    }
    final noop = [for (final c in flat) (handler: 'noop', url: c.url)];
    // The isolate's own time: the calls handled back to back, so no wait for
    // it to wake is counted.
    for (final (label, page) in [('noop handler', noop), ('blockCheck', flat)]) {
      reportSamples('$label, isolate ms per page', samples: await timeRuns(() async {
        for (final call in page) {
          await _ask(call);
        }
      }));
    }
    final rng = Random(7);
    reportSamples('noop handler, ms per call, idle',
        samples: await _deliver(noop, offsets: _oneAtATime(noop.length, rng: rng)));
    final idle = [
      for (var r = 0; r < perfRuns; r++) await _deliver(flat, offsets: _oneAtATime(flat.length, rng: rng)),
    ];
    reportSamples('blockCheck, ms per call, idle', samples: [for (final run in idle) ...run]);
    final busy = await _busy(() async => [
          for (var r = 0; r < perfRuns; r++)
            await _deliver(flat, offsets: _oneAtATime(flat.length, rng: rng)),
        ]);
    reportSamples('blockCheck, ms per call, busy', samples: [for (final run in busy) ...run]);
    reportSamples('ms the page waits for verdicts, idle',
        samples: [for (var r = 0; r < perfRuns; r++) await _pageWait(calls, rng: rng)]);
    reportSamples('ms the page waits for verdicts, busy',
        samples: await _busy(() async => [for (var r = 0; r < perfRuns; r++) await _pageWait(calls, rng: rng)]));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
