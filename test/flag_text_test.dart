import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/widgets/flag_text.dart';

void main() {
  test('a label is cut into its flag and the text after it', () {
    final de = torExitCountryFor('de')!;
    expect(flagRuns(de.label), [
      (text: de.flag, flag: true),
      (text: '  Deutschland (DE)', flag: false),
    ]);
    expect(flagRuns('0.4.2+33'), [(text: '0.4.2+33', flag: false)]);
    expect(flagRuns(''), isEmpty);
  });

  testWidgets('only the flag is drawn in the colour emoji font', (tester) async {
    final de = torExitCountryFor('de')!;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: flagText('Exit: ${de.label}'),
    ));
    final rich = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
    final spans = [for (final s in rich.children!) s as TextSpan];
    expect(spans.map((s) => s.text), ['Exit: ', de.flag, '  Deutschland (DE)']);
    expect(spans.map((s) => s.style?.fontFamily),
        [null, emojiFontFamily, null]);
  });

  testWidgets('text with no flag is a plain Text', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: flagText('Link handling 0.4.2+33'),
    ));
    expect(tester.widget<Text>(find.byType(Text)).data, 'Link handling 0.4.2+33');
  });
}
