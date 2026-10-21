import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/utils/stable_palette.dart';

void main() {
  test(
    'saved identity colors stay compatible across launches and releases',
    () {
      const identities = [
        '__all_webspace__',
        'workspace-work',
        'workspace-personal',
        'workspace-research',
      ];
      expect(
        [for (final id in identities) stablePaletteIndex(id, paletteSize: 4)],
        [1, 0, 1, 0],
      );
      expect(
        [for (final id in identities) stablePaletteIndex(id, paletteSize: 8)],
        [5, 4, 1, 0],
      );
    },
  );
}
