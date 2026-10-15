import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/step_table.dart';

/// The steps that may read, once their await is over, what a write no step
/// takes changed meanwhile ([UnmodeledWrites]): each a timing TLC did not
/// check, owed here with why. A meet not listed fails the run.
const owedMeets = <UnmodeledMeet>{};

/// Holds what the run met to [owedMeets] (Phase 4: a step's reads checked
/// at its commit).
void expectOnlyOwedMeets() => expect(
  UnmodeledWrites.met.difference(owedMeets),
  isEmpty,
  reason: 'a step read what a write no step takes changed while it waited: '
      'take the write in a step, or owe the meet here with why',
);
