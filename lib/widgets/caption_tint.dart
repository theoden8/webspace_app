import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webspace/services/window_caption.dart';

/// Tells the window's header which brightness the app runs in, so its
/// buttons read against the app bar under them (NAV-019). Placed around the
/// navigator, where the app's theme is resolved.
class CaptionTint extends StatefulWidget {
  const CaptionTint({super.key, required this.child, this.caption});

  final Widget child;

  /// [WindowCaption.instance] unless a test gives its own.
  final WindowCaption? caption;

  @override
  State<CaptionTint> createState() => _CaptionTintState();
}

class _CaptionTintState extends State<CaptionTint> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final caption = widget.caption ?? WindowCaption.instance;
    unawaited(caption.follow(Theme.of(context).brightness));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
