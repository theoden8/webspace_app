import 'package:flutter/material.dart';
import 'package:webspace/widgets/page_load_bar.dart';

/// The load progress along the top edge in full screen, where no app bar
/// hosts it. Transparent to pointers: it adds nothing tappable, so a
/// kiosk-locked shell stays sealed (KIOSK-002) and web-app controls in the
/// top corners keep their taps.
class FullscreenLoadBar extends StatelessWidget {
  const FullscreenLoadBar({super.key, required this.progress});

  /// Percent loaded; 0 shows an indeterminate bar.
  final int progress;

  @override
  Widget build(BuildContext context) => Positioned(
    top: MediaQuery.of(context).padding.top,
    left: 0,
    right: 0,
    child: IgnorePointer(
      child: LinearProgressIndicator(
        value: progress > 0 ? progress / 100 : null,
        minHeight: PageLoadBar.height,
        backgroundColor: Colors.transparent,
      ),
    ),
  );
}

/// The handle under the status bar that leaves full screen. Only the handle
/// catches the tap: the rest of the strip stays transparent so a web app's
/// controls in the top corners get theirs (github #401).
class FullscreenExitHandle extends StatelessWidget {
  const FullscreenExitHandle({super.key, required this.onExit});

  final VoidCallback onExit;

  static const double _handleHeight = 5;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: topPadding + 20,
      child: Align(
        alignment: Alignment.topCenter,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onExit,
          child: Container(
            width: 96,
            height: topPadding + 20,
            alignment: Alignment.bottomCenter,
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.only(bottom: 5),
              width: 36,
              height: _handleHeight,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(_handleHeight / 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
