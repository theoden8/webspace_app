import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/virtual_source_preview.dart';

void main() {
  group('buildVirtualSourcePreviewHtml', () {
    const dataUrl = 'data:video/mp4;base64,AAAA';
    final html = buildVirtualSourcePreviewHtml(dataUrl, autoplay: true);

    test('embeds the source and renders a looping muted autoplay video', () {
      expect(html, contains('src="$dataUrl"'));
      // The loop the user asked to be able to see.
      expect(html, contains('loop'));
      expect(html, contains('autoplay'));
      // Muted + inline so it starts without a tap and without sound.
      expect(html, contains('muted'));
      expect(html, contains('playsinline'));
    });

    test('uses cover-fit so the preview matches the framing the site gets', () {
      expect(html, contains('object-fit:cover'));
    });

    test(
        'under reduced motion it rests on its first frame and plays on request '
        '(A11Y-011)', () {
      final still = buildVirtualSourcePreviewHtml(dataUrl, autoplay: false);
      expect(still, isNot(contains('autoplay')));
      expect(still, contains('controls'));
      expect(still, contains('preload="auto"'));
      expect(still, contains('src="$dataUrl"'));
      expect(html, isNot(contains('controls')));
    });
  });
}
