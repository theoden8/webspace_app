import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/svg_style_inliner.dart';

/// A square whose sheet paints it red, green under a dark scheme and blue
/// under a light one, the shape of codeberg's favicon.
const _themed = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
<style>
  /* the base colour */
  rect { fill: #ff0000; }
  @media (prefers-color-scheme: dark) { rect { fill: #00ff00; } }
  @media (prefers-color-scheme: light) { .tile { fill: #0000ff; } }
</style>
<rect class="tile" width="10" height="10"/></svg>''';

/// The colour at the centre of [svg] as flutter_svg draws it.
Future<List<int>> _centre(WidgetTester tester, {required String svg}) async {
  final key = GlobalKey();
  await tester.pumpWidget(Center(
      child: RepaintBoundary(
          key: key, child: SvgPicture.string(svg, width: 20, height: 20))));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pump();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final at = (10 * image.width + 10) * 4;
    return data!.buffer.asUint8List().sublist(at, at + 3).toList();
  }))!;
}

void main() {
  group('ICON-005: the sheet drawn as flutter_svg draws it', () {
    testWidgets('a sheet alone draws the default black', (tester) async {
      expect(await _centre(tester, svg: _themed), [0, 0, 0],
          reason: 'flutter_svg reads no <style>: the premise of the inliner');
    });

    testWidgets('dark draws the dark rule', (tester) async {
      expect(await _centre(tester, svg: inlineSvgStyles(_themed, dark: true)),
          [0, 255, 0]);
    });

    testWidgets('light draws the light rule, whose class outranks the type',
        (tester) async {
      expect(await _centre(tester, svg: inlineSvgStyles(_themed, dark: false)),
          [0, 0, 255]);
    });
  });

  group('ICON-005: what the inliner reads', () {
    String styleOf(String svg, {required String id}) =>
        RegExp('id="$id"[^>]*style="([^"]*)"').firstMatch(svg)?.group(1) ??
        RegExp('style="([^"]*)"[^>]*id="$id"').firstMatch(svg)!.group(1)!;

    test('an element\'s own style wins over the sheet', () {
      const svg = '<svg><style>#a { fill: red; }</style>'
          '<path id="a" style="fill: blue"/></svg>';
      final out = inlineSvgStyles(svg, dark: false);
      expect(styleOf(out, id: 'a'), 'fill: red;fill: blue');
      expect(out, isNot(contains('<style')));
    });

    test('an id outranks a class, a class a type, then sheet order', () {
      const svg = '<svg><style>'
          '#a { fill: id } .c { fill: class } path { fill: type } path { fill: later }'
          '</style><path id="a" class="c"/><path id="b" class="c"/><path id="d"/></svg>';
      final out = inlineSvgStyles(svg, dark: false);
      expect(styleOf(out, id: 'a'), endsWith('fill: id'));
      expect(styleOf(out, id: 'b'), endsWith('fill: class'));
      expect(styleOf(out, id: 'd'), endsWith('fill: later'));
    });

    test('a selector past one element and an at-rule other than the scheme '
        'are skipped', () {
      const svg = '<svg><style>'
          'g path { fill: red } path:hover { fill: red } @import url(x.css);'
          '@media print { path { fill: red } } path > g { fill: red }'
          '@keyframes k { from { fill: red } }'
          '</style><path id="a"/></svg>';
      expect(inlineSvgStyles(svg, dark: true), '<svg><path id="a"/></svg>');
    });

    test('a declaration cannot close the attribute it lands in', () {
      const svg = '<svg><style>path { fill: "x" onload="y" }</style><path id="a"/></svg>';
      final out = inlineSvgStyles(svg, dark: false);
      expect(out, isNot(contains('onload="y"')));
      expect(out, contains('&quot;'));
    });

    test('an SVG past the cap, or with no sheet, is returned unchanged', () {
      const plain = '<svg><path fill="red"/></svg>';
      expect(inlineSvgStyles(plain, dark: true), plain);
      final huge = '<svg><style>path{fill:red}</style>${' ' * maxLength}<path/></svg>';
      expect(inlineSvgStyles(huge, dark: true), huge);
    });

    test('a sheet wrapped in CDATA is read', () {
      const svg = '<svg><style><![CDATA[ path { fill: red } ]]></style><path id="a"/></svg>';
      expect(styleOf(inlineSvgStyles(svg, dark: false), id: 'a'), 'fill: red');
    });
  });
}
