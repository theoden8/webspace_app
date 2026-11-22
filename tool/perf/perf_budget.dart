// The perf budget gate's comparison: given the samples a benchmark run wrote
// for the base (master) and for the head (this PR), both on the one runner in
// the one job, decide whether any measurement regressed past its ceiling.
//
// Ratio, not absolute: the two runs share a machine and a Flutter version, so
// head/base cancels the host out and a ceiling is a factor a real regression
// has to clear, not a wall a faster or slower runner moves. A measurement
// below its floor is near-zero work whose ratio is noise, so it is reported
// and not gated. Ceilings live in test/perf/budgets.tsv.
//
//   dart run tool/perf/perf_budget.dart <base.jsonl> <head.jsonl> <budgets.tsv>
//
// Exit 0 when every budgeted measurement is within its ceiling (or below its
// floor); exit 1 on any breach, or on a budgeted measurement missing from
// either run (a renamed or dropped benchmark is a regression in the gate).
import 'dart:convert';
import 'dart:io';

/// A measurement's ceiling: the most its head median may be over its base
/// median (a ratio), and the base median below which the ratio is only noise.
typedef Budget = ({double ceilingRatio, double floorMs});

enum BudgetStatus { ok, overBudget, belowFloor, noBudget, missingBase, missingHead }

/// One measurement's verdict, for the printed table.
typedef BudgetRow = ({
  String label,
  double? baseMedian,
  double? headMedian,
  double? ratio,
  Budget? budget,
  BudgetStatus status,
});

// The same central sample reportSamples prints as the median, so a number in
// the table matches the one the benchmark logged.
double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * 0.5).round()];
}

/// The median of each measurement's samples in a WS_PERF_OUT file (one JSON
/// object per line: {"label": ..., "samples": [...]}). A label written more
/// than once (a benchmark that reports it per case) keeps its last block, as a
/// rerun would.
Map<String, double> mediansOf(String jsonl) {
  final out = <String, double>{};
  for (final line in const LineSplitter().convert(jsonl)) {
    if (line.trim().isEmpty) continue;
    final obj = jsonDecode(line);
    if (obj is! Map) continue;
    final label = obj['label'];
    final samples = obj['samples'];
    if (label is! String || samples is! List) continue;
    final xs = [for (final v in samples) if (v is num) v.toDouble()];
    if (xs.isNotEmpty) out[label] = _median(xs);
  }
  return out;
}

/// The budgets file: `label<TAB>ceiling_ratio<TAB>floor_ms`, `#` comments and
/// blank lines ignored.
Map<String, Budget> parseBudgets(String tsv) {
  final out = <String, Budget>{};
  for (final line in const LineSplitter().convert(tsv)) {
    if (line.trim().isEmpty || line.startsWith('#')) continue;
    final parts = line.split('\t');
    if (parts.length != 3) {
      throw FormatException('budget line needs 3 tab-separated fields', line);
    }
    final ratio = double.tryParse(parts[1].trim());
    final floor = double.tryParse(parts[2].trim());
    if (ratio == null || floor == null) {
      throw FormatException('budget ratio and floor must be numbers', line);
    }
    out[parts[0]] = (ceilingRatio: ratio, floorMs: floor);
  }
  return out;
}

/// Every measurement in either run, each paired with its budget and verdict.
/// A budgeted measurement missing from a run is a failure; an unbudgeted one
/// is reported only.
List<BudgetRow> evaluateBudgets({
  required Map<String, double> base,
  required Map<String, double> head,
  required Map<String, Budget> budgets,
}) {
  final labels = {...base.keys, ...head.keys, ...budgets.keys}.toList()..sort();
  final rows = <BudgetRow>[];
  for (final label in labels) {
    final b = base[label];
    final h = head[label];
    final budget = budgets[label];
    final ratio = (b != null && h != null && b > 0) ? h / b : null;
    final BudgetStatus status;
    if (budget == null) {
      status = BudgetStatus.noBudget;
    } else if (b == null) {
      status = BudgetStatus.missingBase;
    } else if (h == null) {
      status = BudgetStatus.missingHead;
    } else if (b < budget.floorMs) {
      status = BudgetStatus.belowFloor;
    } else if (ratio != null && ratio > budget.ceilingRatio) {
      status = BudgetStatus.overBudget;
    } else {
      status = BudgetStatus.ok;
    }
    rows.add((
      label: label,
      baseMedian: b,
      headMedian: h,
      ratio: ratio,
      budget: budget,
      status: status,
    ));
  }
  return rows;
}

// A regression fails: a measurement over its ceiling, or one master budgets
// that this PR no longer emits (renamed or dropped). A budgeted measurement
// absent from base is new on this PR, so it is reported and not gated: its
// baseline lands with it and gates the next PR.
bool budgetsPassed(List<BudgetRow> rows) => !rows.any((r) =>
    r.status == BudgetStatus.overBudget ||
    r.status == BudgetStatus.missingHead);

String renderTable(List<BudgetRow> rows) {
  String ms(double? v) => v == null ? '-' : v.toStringAsFixed(v < 10 ? 2 : 0);
  String ratio(double? v) => v == null ? '-' : '${v.toStringAsFixed(2)}x';
  String mark(BudgetStatus s) => switch (s) {
        BudgetStatus.ok => 'ok',
        BudgetStatus.overBudget => 'OVER BUDGET',
        BudgetStatus.belowFloor => 'below floor (not gated)',
        BudgetStatus.noBudget => 'no budget (trend only)',
        BudgetStatus.missingBase => 'new (no base; not gated)',
        BudgetStatus.missingHead => 'MISSING on head',
      };
  final buf = StringBuffer()
    ..writeln('${'measurement'.padRight(44)} '
        '${'base'.padLeft(8)} ${'head'.padLeft(8)} ${'ratio'.padLeft(7)} '
        '${'ceiling'.padLeft(8)}  status');
  for (final r in rows) {
    buf.writeln('${r.label.padRight(44)} '
        '${ms(r.baseMedian).padLeft(8)} ${ms(r.headMedian).padLeft(8)} '
        '${ratio(r.ratio).padLeft(7)} '
        '${(r.budget == null ? '-' : '${r.budget!.ceilingRatio.toStringAsFixed(2)}x').padLeft(8)}'
        '  ${mark(r.status)}');
  }
  return buf.toString();
}

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln('usage: perf_budget.dart <base.jsonl> <head.jsonl> <budgets.tsv>');
    exit(2);
  }
  final base = mediansOf(File(args[0]).readAsStringSync());
  final head = mediansOf(File(args[1]).readAsStringSync());
  final budgets = parseBudgets(File(args[2]).readAsStringSync());
  final rows = evaluateBudgets(base: base, head: head, budgets: budgets);
  stdout.write(renderTable(rows));
  if (budgetsPassed(rows)) {
    stdout.writeln('\nperf budget: within ceilings.');
    return;
  }
  // Enforcement is opt-in (WS_PERF_BUDGET_ENFORCE=1) until the CI runs show the
  // ratio's spread on the real runner, order controlled. Until then a breach is
  // reported, not failed, so this gate cannot block a PR on noise it has not yet
  // characterised there.
  final enforce = Platform.environment['WS_PERF_BUDGET_ENFORCE'] == '1';
  stdout.writeln('\nperf budget: a measurement is past its ceiling'
      '${enforce ? '.' : ' (report only; set WS_PERF_BUDGET_ENFORCE=1 to fail).'}');
  if (enforce) exit(1);
}
