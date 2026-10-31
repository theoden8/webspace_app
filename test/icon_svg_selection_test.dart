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

  group('loadUntrustedSvg', () {
    test('a <use> that names its own parent compiles, the loop drawn empty',
        () async {
      const recursive = '<svg xmlns="http://www.w3.org/2000/svg" width="10" '
          'height="10"><g id="a"><use href="#a"/></g></svg>';
      expect(await loadUntrustedSvg(recursive), isNotNull);
    });

    test('nesting deep enough to overflow the stack is rejected', () async {
      const depth = 100000;
      final deep = '<svg xmlns="http://www.w3.org/2000/svg" width="10" '
          'height="10">${'<g>' * depth}<rect width="1" height="1"/>'
          '${'</g>' * depth}</svg>';
      expect(await loadUntrustedSvg(deep), isNull);
    });

    test('references that expand past the compiler cap are rejected',
        () async {
      final svg = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" '
          'width="10" height="10"><defs><rect id="l0" width="1" height="1"/>');
      for (var level = 1; level < 12; level++) {
        svg.write('<g id="l$level">'
            '${'<use href="#l${level - 1}"/>' * 10}</g>');
      }
      svg.write('</defs><use href="#l11"/></svg>');
      expect(await loadUntrustedSvg(svg.toString()), isNull);
    });
  });

  group('svgHasRealColor (ICON-004)', () {
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
