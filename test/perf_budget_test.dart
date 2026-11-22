// The perf budget gate's comparison logic (tool/perf/perf_budget.dart): the
// ratio, the floor, a dropped measurement, a new one, and parsing. The gate
// itself (scripts/perf_budget.sh) runs the benchmarks on two refs; this pins
// the decision it makes on their numbers.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';

import '../tool/perf/perf_budget.dart';

void main() {
  const budgets = <String, Budget>{
    'cheap': (ceilingRatio: 1.30, floorMs: 2.0),
    'tiny': (ceilingRatio: 1.30, floorMs: 50.0),
  };

  BudgetRow rowFor(String label, {required List<BudgetRow> among}) =>
      among.firstWhere((r) => r.label == label);

  test('within the ceiling passes', () {
    final rows = evaluateBudgets(
      base: {'cheap': 10.0},
      head: {'cheap': 12.0}, // 1.20x < 1.30x
      budgets: budgets,
    );
    expect(rowFor('cheap', among: rows).status, BudgetStatus.ok);
    expect(budgetsPassed(rows), isTrue);
  });

  test('past the ceiling fails', () {
    final rows = evaluateBudgets(
      base: {'cheap': 10.0},
      head: {'cheap': 14.0}, // 1.40x > 1.30x
      budgets: budgets,
    );
    expect(rowFor('cheap', among: rows).status, BudgetStatus.overBudget);
    expect(budgetsPassed(rows), isFalse);
  });

  test('a base below the floor is not gated however large the ratio', () {
    final rows = evaluateBudgets(
      base: {'tiny': 10.0}, // < 50ms floor
      head: {'tiny': 90.0}, // 9x, but noise on near-zero work
      budgets: budgets,
    );
    expect(rowFor('tiny', among: rows).status, BudgetStatus.belowFloor);
    expect(budgetsPassed(rows), isTrue);
  });

  test('an unbudgeted measurement is reported, not gated', () {
    final rows = evaluateBudgets(
      base: {'other': 10.0},
      head: {'other': 1000.0},
      budgets: budgets,
    );
    expect(rowFor('other', among: rows).status, BudgetStatus.noBudget);
    expect(budgetsPassed(rows), isTrue);
  });

  test('a budgeted measurement gone from the head fails (renamed or dropped)', () {
    final rows = evaluateBudgets(
      base: {'cheap': 10.0},
      head: <String, double>{},
      budgets: budgets,
    );
    expect(rowFor('cheap', among: rows).status, BudgetStatus.missingHead);
    expect(budgetsPassed(rows), isFalse);
  });

  test('a budgeted measurement new on the head is reported, not gated', () {
    final rows = evaluateBudgets(
      base: <String, double>{},
      head: {'cheap': 10.0},
      budgets: budgets,
    );
    expect(rowFor('cheap', among: rows).status, BudgetStatus.missingBase);
    expect(budgetsPassed(rows), isTrue);
  });

  test('mediansOf takes the median and the last block of a repeated label', () {
    final m = mediansOf([
      '{"label":"a","samples":[3,1,2]}',
      '{"label":"a","samples":[10,10,40]}', // a reported twice; last wins
      '',
      '{"label":"b","samples":[5]}',
    ].join('\n'));
    expect(m['a'], 10); // median of [10,10,40]
    expect(m['b'], 5);
  });

  test('parseBudgets reads rows and rejects a malformed line', () {
    final b = parseBudgets('# header\nx\t1.5\t20\n\ny\t2.0\t0');
    expect(b['x'], (ceilingRatio: 1.5, floorMs: 20.0));
    expect(b['y'], (ceilingRatio: 2.0, floorMs: 0.0));
    expect(() => parseBudgets('bad\tline'), throwsFormatException);
    expect(() => parseBudgets('x\tnotnum\t1'), throwsFormatException);
  });
}
