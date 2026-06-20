import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('svgRendersBlank', () {
    test("duck.ai's nested-<svg> favicon renders blank under flutter_svg",
        () async {
      final duck =
          File('test/fixtures/duck_ai_favicon.svg').readAsStringSync();
      expect(await svgRendersBlank(duck), isTrue);
    });

    test('a flat colored SVG renders visibly', () async {
      const flat =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
          '<rect width="32" height="32" fill="#de5833"/></svg>';
      expect(await svgRendersBlank(flat), isFalse);
    });

    test('malformed SVG does not get punished (probe failure => not blank)',
        () async {
      expect(await svgRendersBlank('not an svg at all'), isFalse);
    });
  });

  group('svgHasRealColor', () {
    test('detects attribute hex color', () {
      expect(svgHasRealColor('<path fill="#de5833"/>'.toLowerCase()), isTrue);
    });

    test('ignores black/white/grey', () {
      expect(
          svgHasRealColor('<path fill="#000"/><path fill="#fff"/>'), isFalse);
    });
  });

  group('svgHasMaskingStyleToggle', () {
    test('flags CSS display:none theme toggle', () {
      const svg =
          '<svg><style>@media (prefers-color-scheme: dark){.l{display:none}}'
          '</style></svg>';
      expect(svgHasMaskingStyleToggle(svg.toLowerCase()), isTrue);
    });

    test('plain SVG is fine', () {
      expect(svgHasMaskingStyleToggle('<svg><path fill="#de5833"/></svg>'),
          isFalse);
    });
  });
}
