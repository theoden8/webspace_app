import 'package:flutter/widgets.dart';

/// The colour emoji font, named on a flag alone: as a fallback of the whole
/// theme it came first for every character, and its keycap bases (the space
/// and the digits) drew emoji-wide on Linux. Without it, the platform's
/// fallback can pick a font that draws a flag's indicators as boxed letters
/// (Adwaita Mono).
const emojiFontFamily = 'Noto Color Emoji';

/// [text] with each run of regional indicators (a flag) drawn in
/// [emojiFontFamily] and everything else in [style]'s own font; a plain
/// `Text` when it holds no flag.
Text flagText(String text, {TextStyle? style}) {
  final runs = flagRuns(text);
  if (!runs.any((r) => r.flag)) return Text(text, style: style);
  return Text.rich(
    TextSpan(children: [
      for (final r in runs)
        TextSpan(
          text: r.text,
          style: r.flag ? const TextStyle(fontFamily: emojiFontFamily) : null,
        ),
    ]),
    style: style,
  );
}

/// [text] cut where it enters or leaves a run of regional indicators.
List<({String text, bool flag})> flagRuns(String text) {
  final runs = <({String text, bool flag})>[];
  final run = StringBuffer();
  bool? inFlag;
  for (final rune in text.runes) {
    final flag = rune >= 0x1F1E6 && rune <= 0x1F1FF;
    if (inFlag != null && flag != inFlag) {
      runs.add((text: run.toString(), flag: inFlag));
      run.clear();
    }
    inFlag = flag;
    run.writeCharCode(rune);
  }
  if (inFlag != null) runs.add((text: run.toString(), flag: inFlag));
  return runs;
}
