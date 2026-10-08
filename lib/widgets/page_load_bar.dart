import 'package:flutter/material.dart';

/// Page-load progress under an app bar. While nothing loads it keeps its
/// height, so the page below does not jump when a load starts.
class PageLoadBar extends StatelessWidget implements PreferredSizeWidget {
  const PageLoadBar({super.key, required this.loading, required this.progress});

  static const double height = 3.0;

  final bool loading;

  /// Percent loaded; 0 shows an indeterminate bar.
  final int progress;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) => loading
      ? LinearProgressIndicator(
          value: progress > 0 ? progress / 100 : null,
          minHeight: height,
          backgroundColor: Colors.transparent,
        )
      : const SizedBox(height: height);
}
