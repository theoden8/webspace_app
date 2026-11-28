import 'package:flutter/widgets.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The scheme a site's webview was last told and the app's background drawn
/// under it in that scheme (A11Y-008). A webview first told dark is built
/// transparent, so the frames before its page paints show this surface
/// rather than the engine's white; the surface then follows each later
/// telling, so a page with no background of its own sits on its own scheme.
final class PageBackdrop {
  PageBackdrop({required Brightness told})
      : _told = ValueNotifier(told),
        transparent = told == Brightness.dark;

  final ValueNotifier<Brightness> _told;

  /// Whether the webview is built with no background of its own. One first
  /// told light keeps the engine's opaque white, which a light page paints
  /// over and which a dark scheme told later repaints dark.
  final bool transparent;

  void tell(Brightness told) => _told.value = told;

  /// [webView] over the surface of the scheme last told.
  Widget under(Widget webView) => ValueListenableBuilder<Brightness>(
        valueListenable: _told,
        builder: (context, told, child) =>
            ColoredBox(color: appBackground(told), child: child),
        child: webView,
      );
}
