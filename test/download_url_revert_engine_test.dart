import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/download_url_revert_engine.dart';

void main() {
  group('DownloadUrlRevertEngine.isRenderable', () {
    test('true for http/https/file/about', () {
      expect(DownloadUrlRevertEngine.isRenderable('https://example.com/'),
          isTrue);
      expect(DownloadUrlRevertEngine.isRenderable('http://example.com/'),
          isTrue);
      expect(
          DownloadUrlRevertEngine.isRenderable('file:///tmp/x.html'), isTrue);
      expect(DownloadUrlRevertEngine.isRenderable('about:blank'), isTrue);
    });

    test('false for data:/blob:/javascript:/chrome:', () {
      expect(
          DownloadUrlRevertEngine.isRenderable('data:text/plain,hello'),
          isFalse);
      expect(DownloadUrlRevertEngine.isRenderable('blob:https://x/abc'),
          isFalse);
      expect(DownloadUrlRevertEngine.isRenderable('javascript:alert(1)'),
          isFalse);
      expect(DownloadUrlRevertEngine.isRenderable('chrome://settings'),
          isFalse);
    });

    test('false for empty and malformed', () {
      expect(DownloadUrlRevertEngine.isRenderable(''), isFalse);
      // Uri.parse is lenient; scheme is '' for bare strings.
      expect(
          DownloadUrlRevertEngine.isRenderable('not a url at all'), isFalse);
    });

    test('case-insensitive on scheme', () {
      expect(DownloadUrlRevertEngine.isRenderable('HTTPS://example.com/'),
          isTrue);
      expect(
          DownloadUrlRevertEngine.isRenderable('Data:text/plain,x'), isFalse);
    });
  });

  group('DownloadUrlRevertEngine.updateStable', () {
    test('renderable URL replaces previous', () {
      expect(
        DownloadUrlRevertEngine.updateStable(
            'https://old/', 'https://new/'),
        'https://new/',
      );
    });

    test('non-renderable URL preserves previous', () {
      expect(
        DownloadUrlRevertEngine.updateStable(
            'https://old/', 'data:text/plain,x'),
        'https://old/',
      );
      expect(
        DownloadUrlRevertEngine.updateStable(
            'https://old/', 'blob:https://old/abc'),
        'https://old/',
      );
    });

    test('first renderable load seeds the stable value', () {
      expect(
        DownloadUrlRevertEngine.updateStable(null, 'https://x/'),
        'https://x/',
      );
    });

    test('non-renderable load with no previous returns null', () {
      expect(
        DownloadUrlRevertEngine.updateStable(null, 'data:text/plain,x'),
        isNull,
      );
    });
  });

  group('DownloadUrlRevertEngine.pickRevertTarget', () {
    test('prefers lastStableUrl over initialUrl', () {
      expect(
        DownloadUrlRevertEngine.pickRevertTarget(
          lastStableUrl: 'https://stable/',
          initialUrl: 'https://init/',
        ),
        'https://stable/',
      );
    });

    test('falls back to initialUrl when stable is null', () {
      expect(
        DownloadUrlRevertEngine.pickRevertTarget(
          lastStableUrl: null,
          initialUrl: 'https://init/',
        ),
        'https://init/',
      );
    });

    test('returns null when both are null', () {
      expect(
        DownloadUrlRevertEngine.pickRevertTarget(),
        isNull,
      );
    });
  });
}
