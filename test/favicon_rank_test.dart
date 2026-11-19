import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/favicon_rank.dart';
import 'package:webspace/third_party/favicon/favicon.dart';

void main() {
  group('FaviconRank (ICON-003)', () {
    Favicon best(List<Favicon> icons, {Map<String, bool> colored = const {}}) {
      final rank = FaviconRank(colored: colored);
      return (icons.toList()..sort((a, b) => rank.compare(a, b: b))).first;
    }

    test('a colored SVG wins over every PNG and scores 1000', () {
      const logo = 'https://a.example/logo.svg';
      final icons = [
        Favicon('https://a.example/icon-192.png', width: 192, height: 192),
        Favicon(logo),
        Favicon('https://a.example/icon-32.png', width: 32, height: 32),
      ];
      final rank = FaviconRank(colored: const {logo: true});
      final chosen = best(icons, colored: const {logo: true});
      expect(chosen.url, logo);
      expect(rank.score(chosen), 1000);
    });

    test('among rasters the larger wins and scores its width', () {
      final icons = [
        Favicon('https://a.example/32.png', width: 32, height: 32),
        Favicon('https://a.example/64.png', width: 64, height: 64),
      ];
      final chosen = best(icons);
      expect(chosen.url, 'https://a.example/64.png');
      expect(const FaviconRank(colored: {}).score(chosen), 64);
    });

    test('a monochrome SVG loses to a raster and scores 30', () {
      const mark = 'https://a.example/mark.svg';
      final icons = [
        Favicon(mark),
        Favicon('https://a.example/favicon.ico'),
      ];
      final chosen = best(icons, colored: const {mark: false});
      expect(chosen.url, 'https://a.example/favicon.ico');
      const rank = FaviconRank(colored: {mark: false});
      expect(rank.score(Favicon(mark)), 30);
      expect(rank.score(chosen), 50, reason: 'a raster of unknown width');
    });

    test('a colored SVG wins over a monochrome one', () {
      const mono = 'https://a.example/m.svg';
      const color = 'https://a.example/colored-logo.svg';
      expect(
        best([Favicon(mono), Favicon(color)],
                colored: const {mono: false, color: true})
            .url,
        color,
      );
    });
  });
}
