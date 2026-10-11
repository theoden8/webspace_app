// How the benchmarks here report: the median and spread of each measurement,
// and with WS_PERF_OUT set, every sample as one JSON line per measurement, so
// two checkouts can be compared by distribution rather than by one number.
import 'dart:convert';
import 'dart:io';

/// Samples per measurement; WS_PERF_RUNS overrides.
final int perfRuns = int.tryParse(Platform.environment['WS_PERF_RUNS'] ?? '') ?? 5;

final String? _out = Platform.environment['WS_PERF_OUT'];

double elapsedMs(Stopwatch sw) => sw.elapsedMicroseconds / 1000;

/// Prints the median with the 10th and 90th percentiles of [samples] (ms).
void reportSamples(String label, {required List<double> samples}) {
  final sorted = [...samples]..sort();
  double at(double q) => sorted[((sorted.length - 1) * q).round()];
  String ms(double v) => v.toStringAsFixed(v < 10 ? 2 : 0);
  // ignore: avoid_print
  print('${label.padRight(56)} ${ms(at(0.5)).padLeft(7)} ms'
      '  [p10 ${ms(at(0.1))}, p90 ${ms(at(0.9))}, n=${sorted.length}]');
  final out = _out;
  if (out != null) {
    File(out).writeAsStringSync('${jsonEncode({'label': label, 'samples': samples})}\n',
        mode: FileMode.append);
  }
}

/// [perfRuns] timings of [body], in ms.
Future<List<double>> timeRuns(Future<void> Function() body) async => [
      for (var i = 0; i < perfRuns; i++)
        await () async {
          final sw = Stopwatch()..start();
          await body();
          return elapsedMs(sw);
        }(),
    ];
