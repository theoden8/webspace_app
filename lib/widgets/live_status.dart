import 'package:flutter/material.dart';

/// A line of status that changes while focus is elsewhere (a find count,
/// Tor's progress), which a screen reader announces as it changes.
class LiveStatus extends StatelessWidget {
  const LiveStatus(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Text(text, style: style, textAlign: textAlign),
  );
}
