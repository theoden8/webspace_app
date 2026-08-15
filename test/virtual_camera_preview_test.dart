import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/virtual_camera_preview.dart';

void main() {
  group('buildVirtualCameraPreviewHtml', () {
    const dataUrl = 'data:video/mp4;base64,AAAA';
    final html = buildVirtualCameraPreviewHtml(dataUrl);

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
  });
}
