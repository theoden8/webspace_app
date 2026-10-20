import 'package:flutter_test/flutter_test.dart';

import 'helpers/walk/shards.dart';

void main() {
  test(
    'script shards cover every item once and preserve their local order',
    () {
      for (final size in [0, 1, 7, 49, 343]) {
        final scripts = List.generate(size, (i) => i);
        for (final count in [1, 2, 3, 4, 8, 16]) {
          final parts = [
            for (var i = 0; i < count; i++)
              shardItems(scripts, index: i, count: count).toList(),
          ];
          final together = parts.expand((part) => part).toList();
          final reason = '$size scripts in $count shards';
          expect(together.length, scripts.length, reason: reason);
          expect(together.toSet().length, scripts.length, reason: reason);
          expect(together.toSet(), scripts.toSet(), reason: reason);
          for (final part in parts) {
            expect(part, orderedEquals([...part]..sort()), reason: reason);
          }
        }
      }
    },
  );
}
