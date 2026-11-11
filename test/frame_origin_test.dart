import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/frame_origin.dart';

/// A [FrameOrigin] is made only from platform frame data or a permission
/// request, never a page string (PERM-001). The compiler is the probe: there
/// is no public `String` constructor, so `FrameOrigin.ofFrame('https://evil')`
/// does not compile (`ofFrame` takes a [inapp.JavaScriptHandlerFunctionData]),
/// and `FrameOrigin._` is library-private. These cases pin the one thing a test
/// can show: each factory carries the engine's origin, normalized by `originOf`.
void main() {
  inapp.JavaScriptHandlerFunctionData frame(String origin) =>
      inapp.JavaScriptHandlerFunctionData(
        isMainFrame: true,
        origin: inapp.WebUri(origin),
        requestUrl: inapp.WebUri(origin),
      );

  group('FrameOrigin carries the engine-reported origin (PERM-001)', () {
    test('a bridge frame normalizes to scheme://host[:port]', () {
      expect(
        FrameOrigin.ofFrame(frame('https://a.test:443/some/path?q=1')),
        'https://a.test',
      );
      expect(
        FrameOrigin.ofFrame(frame('http://b.test:8080/')),
        'http://b.test:8080',
      );
    });

    test('a platform permission request normalizes the same way', () {
      expect(
        FrameOrigin.ofRequest(
          inapp.PermissionRequest(origin: inapp.WebUri('https://c.test/x')),
        ),
        'https://c.test',
      );
    });

    test('it reads as the origin text it is (implements String)', () {
      final String asString = FrameOrigin.ofFrame(frame('https://d.test/'));
      expect(asString, 'https://d.test');
      expect(
        Uri.parse(FrameOrigin.ofFrame(frame('https://e.test/'))).host,
        'e.test',
      );
    });
  });
}
