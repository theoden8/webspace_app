import 'package:webspace/third_party/favicon/favicon.dart';

/// Which of a page's declared icons is best and what it scores (ICON-003):
/// a colored SVG first, then rasters by area, a monochrome SVG last; a
/// colored SVG scores 1000, a raster its width (50 when unknown), a
/// monochrome SVG 30.
final class FaviconRank {
  const FaviconRank({required this.colored});

  /// Whether each SVG's markup carries color, by URL; an SVG absent is
  /// monochrome.
  final Map<String, bool> colored;

  bool _svg(Favicon f) => f.url.endsWith('.svg');
  bool _colored(Favicon f) => colored[f.url] ?? false;

  int score(Favicon f) => _svg(f)
      ? (_colored(f) ? 1000 : 30)
      : (f.width > 0 ? f.width : 50);

  int compare(Favicon a, {required Favicon b}) {
    final aSvg = _svg(a);
    final bSvg = _svg(b);
    if (aSvg && bSvg) {
      final aColored = _colored(a);
      final bColored = _colored(b);
      if (aColored && !bColored) return -1;
      if (!aColored && bColored) return 1;
      if (!aColored && !bColored) return 1;
    }
    if (aSvg && !bSvg && !_colored(a)) return 1;
    if (bSvg && !aSvg && !_colored(b)) return -1;
    return a.compareTo(b);
  }
}
