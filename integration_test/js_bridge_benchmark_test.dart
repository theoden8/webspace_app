// JS<->Dart bridge wall-clock bench for the content/DNS blocking hot path.
//
// The pure-Dart benches in test/dns_block_benchmark_test.dart and
// test/dns_block_alternatives_benchmark_test.dart measure the in-process
// algorithm cost only. On iOS/macOS sub-resource blocking actually
// roundtrips through window.flutter_inappwebview.callHandler('blockCheck',
// url) for every Bloom-positive URL. That JS->Dart->JS hop has a fixed
// per-call floor that no in-process bench can see. This test fills the
// gap by driving a real platform WebView and timing back-to-back
// callHandler invocations.
//
// Three variants:
//   noop          — handler returns false immediately. Establishes the
//                   bridge floor (serialisation + IPC + reply), nothing
//                   else.
//   blockcheck_empty
//                 — wires up the production blockCheck handler with
//                   empty DNS+ABP rule sets. isBlocked() short-circuits
//                   on _blockedDomains.isEmpty. Roughly: bridge + one
//                   Set.isEmpty check.
//   blockcheck_seeded
//                 — seeds DnsBlockService with 100k synthetic domains
//                   plus a 5k ABP set. Each iteration uses a fresh host
//                   (no per-host cache hit) so we exercise Bloom +
//                   suffix walk + cache insert per call.
//
// Each variant runs N=500 sequential awaited calls. Sequential because
// p50/p99 per-call latency is the metric; parallel queueing would hide
// the per-call cost behind throughput. Numbers print as
// "p50/p90/p99/max us" plus throughput. Run on the platform you want
// to measure — bridge cost differs between WKWebView, AndroidX WebView
// and WPE WebKit.
//
// Headless Linux harness: see openspec/specs/integration-tests/spec.md.
//
// Usage:
//   fvm flutter test integration_test/js_bridge_benchmark_test.dart
//
// Or against a connected device:
//   fvm flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/js_bridge_benchmark_test.dart \
//     -d <device-id>

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';

const int _iterations = 500;

class _Result {
  _Result(this.label, this.samplesUs, this.totalMs);
  final String label;
  final List<int> samplesUs;
  final double totalMs;

  int _pct(double q) {
    final sorted = [...samplesUs]..sort();
    final idx = (sorted.length * q).floor().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  @override
  String toString() {
    final p50 = _pct(0.50);
    final p90 = _pct(0.90);
    final p99 = _pct(0.99);
    final max = (samplesUs.isEmpty
        ? 0
        : (samplesUs.reduce((a, b) => a > b ? a : b)));
    final mean = samplesUs.isEmpty
        ? 0
        : samplesUs.reduce((a, b) => a + b) / samplesUs.length;
    final throughput = samplesUs.isEmpty
        ? 0
        : (1e6 * samplesUs.length / (totalMs * 1000));
    return '[$label] n=${samplesUs.length} '
        'p50=${p50}us p90=${p90}us p99=${p99}us max=${max}us '
        'mean=${mean.toStringAsFixed(1)}us '
        'total=${totalMs.toStringAsFixed(1)}ms '
        'thru=${throughput.toStringAsFixed(0)}/s';
  }
}

Future<_Result> _runVariant({
  required WidgetTester tester,
  required String label,
  required void Function(inapp.InAppWebViewController) installHandlers,
  required String jsHandlerName,
  required int iterations,
}) async {
  final ready = Completer<inapp.InAppWebViewController>();
  final done = Completer<_Result>();
  late inapp.InAppWebViewController controller;

  // The JS driver lives in the page. It awaits each callHandler
  // sequentially (Promise chain) and records (b - a) per call using
  // performance.now(). Running the loop in JS rather than Dart keeps
  // the measured cost equal to one bridge roundtrip; if Dart drove the
  // loop with controller.evaluateJavascript we'd be measuring TWO
  // roundtrips per iteration (call out, call back).
  final html = '''
<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<script>
async function bench(handler, n) {
  const samples = new Array(n);
  // Synthetic hosts. Vary per-iteration so the production blockCheck
  // host cache (HostFifoCache) doesn't degenerate to a hot single-key
  // load. 6-char tail keeps URLs short to minimise serialisation cost
  // outside the actual bridge floor.
  const tail = 'abcdefghijklmnopqrstuvwxyz';
  function host(i) {
    let s = 'b';
    let v = i;
    for (let k = 0; k < 5; k++) { s += tail[v % 26]; v = (v / 26) | 0; }
    return s + '.example.test';
  }
  const t0 = performance.now();
  for (let i = 0; i < n; i++) {
    const url = 'https://' + host(i) + '/r';
    const a = performance.now();
    await window.flutter_inappwebview.callHandler(handler, url);
    const b = performance.now();
    samples[i] = Math.round((b - a) * 1000); // microseconds
  }
  const total = performance.now() - t0;
  await window.flutter_inappwebview.callHandler('benchDone', {
    samples: samples,
    totalMs: total,
  });
}
window.__startBench = bench;
</script>
</body></html>
''';

  final widget = MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 240,
        child: inapp.InAppWebView(
          initialData: inapp.InAppWebViewInitialData(
            data: html,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: inapp.WebUri('about:blank'),
          ),
          onWebViewCreated: (c) {
            controller = c;
            installHandlers(c);
            c.addJavaScriptHandler(
              handlerName: 'benchDone',
              callback: (args) {
                if (done.isCompleted) return null;
                final m = args.first as Map;
                final raw = (m['samples'] as List).cast<num>();
                final samples = raw.map((e) => e.toInt()).toList();
                final totalMs = (m['totalMs'] as num).toDouble();
                done.complete(_Result(label, samples, totalMs));
                return null;
              },
            );
          },
          onLoadStop: (c, _) {
            if (!ready.isCompleted) ready.complete(c);
          },
        ),
      ),
    ),
  );

  await tester.pumpWidget(widget);

  // pumpAndSettle won't return while the WebView is animating frames,
  // so drive the test with explicit pumps + a wall-clock timeout.
  final readyDeadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready.isCompleted && DateTime.now().isBefore(readyDeadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready.isCompleted, true,
      reason: 'WebView did not reach onLoadStop within 30s');

  await controller.evaluateJavascript(
    source: 'window.__startBench(${_jsString(jsHandlerName)}, $iterations);',
  );

  final benchDeadline = DateTime.now().add(const Duration(minutes: 2));
  while (!done.isCompleted && DateTime.now().isBefore(benchDeadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done.isCompleted, true,
      reason: 'Bench did not report results within 2min');

  return done.future;
}

String _jsString(String s) {
  final escaped = s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return "'$escaped'";
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('JS bridge: noop handler floor', (tester) async {
    final r = await _runVariant(
      tester: tester,
      label: 'noop',
      iterations: _iterations,
      installHandlers: (c) {
        c.addJavaScriptHandler(
          handlerName: 'noop',
          callback: (args) => false,
        );
      },
      jsHandlerName: 'noop',
    );
    debugPrint(r.toString());
  });

  testWidgets('JS bridge: blockCheck shape, empty rules', (tester) async {
    DnsBlockService.instance.loadDomainsFromString('');
    ContentBlockerService.instance.setRustEngineForTest(null);
    final r = await _runVariant(
      tester: tester,
      label: 'blockcheck_empty',
      iterations: _iterations,
      installHandlers: (c) {
        c.addJavaScriptHandler(
          handlerName: 'blockCheck',
          callback: (args) {
            if (args.isEmpty || args[0] is! String) return false;
            final url = args[0] as String;
            if (DnsBlockService.instance.isBlocked(url)) return true;
            if (ContentBlockerService.instance.isBlocked(url)) return true;
            return false;
          },
        );
      },
      jsHandlerName: 'blockCheck',
    );
    debugPrint(r.toString());
  });

  testWidgets('JS bridge: blockCheck shape, 100k DNS + 5k ABP seeded',
      (tester) async {
    final dnsBuf = StringBuffer();
    for (var i = 0; i < 100000; i++) {
      dnsBuf.writeln('seed-$i.tracker.test');
    }
    DnsBlockService.instance.loadDomainsFromString(dnsBuf.toString());

    final abpRulesBuf = StringBuffer();
    for (var i = 0; i < 5000; i++) {
      abpRulesBuf.writeln('||ad-$i.adnet.test^');
    }
    final abpEngine = AdblockEngine.load(abpRulesBuf.toString());
    ContentBlockerService.instance.setRustEngineForTest(abpEngine);

    final r = await _runVariant(
      tester: tester,
      label: 'blockcheck_seeded',
      iterations: _iterations,
      installHandlers: (c) {
        c.addJavaScriptHandler(
          handlerName: 'blockCheck',
          callback: (args) {
            if (args.isEmpty || args[0] is! String) return false;
            final url = args[0] as String;
            if (DnsBlockService.instance.isBlocked(url)) return true;
            if (ContentBlockerService.instance.isBlocked(url)) return true;
            return false;
          },
        );
      },
      jsHandlerName: 'blockCheck',
    );
    debugPrint(r.toString());
  });
}
