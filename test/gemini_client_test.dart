import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/gemini_client.dart';

void main() {
  group('GeminiClient.isGeminiUrl', () {
    test('returns true for gemini:// URLs', () {
      expect(GeminiClient.isGeminiUrl('gemini://example.com'), isTrue);
      expect(GeminiClient.isGeminiUrl('gemini://example.com/page'), isTrue);
      expect(GeminiClient.isGeminiUrl('gemini://example.com:1965/'), isTrue);
    });

    test('returns false for non-gemini URLs', () {
      expect(GeminiClient.isGeminiUrl('https://example.com'), isFalse);
      expect(GeminiClient.isGeminiUrl('http://example.com'), isFalse);
      expect(GeminiClient.isGeminiUrl(''), isFalse);
      expect(GeminiClient.isGeminiUrl('example.com'), isFalse);
    });

    test('returns false for gemini-like but wrong prefix', () {
      expect(GeminiClient.isGeminiUrl('gemini:example.com'), isFalse);
      expect(GeminiClient.isGeminiUrl('geminifoo://example.com'), isFalse);
    });
  });

  group('GeminiResponse', () {
    test('isSuccess for 2x status codes', () {
      expect(
        const GeminiResponse(status: 20, meta: 'text/gemini', body: 'hi')
            .isSuccess,
        isTrue,
      );
      expect(
        const GeminiResponse(status: 29, meta: '', body: '').isSuccess,
        isTrue,
      );
    });

    test('isRedirect for 3x status codes', () {
      expect(
        const GeminiResponse(status: 30, meta: 'gemini://other.com', body: '')
            .isRedirect,
        isTrue,
      );
      expect(
        const GeminiResponse(status: 31, meta: '', body: '').isRedirect,
        isTrue,
      );
    });

    test('isInput for 1x status codes', () {
      expect(
        const GeminiResponse(status: 10, meta: 'Enter query', body: '')
            .isInput,
        isTrue,
      );
    });

    test('isError for 4x, 5x, 6x status codes', () {
      expect(
        const GeminiResponse(status: 40, meta: 'Temporary failure', body: '')
            .isError,
        isTrue,
      );
      expect(
        const GeminiResponse(status: 51, meta: 'Not found', body: '')
            .isError,
        isTrue,
      );
      expect(
        const GeminiResponse(status: 60, meta: 'Client cert required', body: '')
            .isError,
        isTrue,
      );
    });

    test('mimeType extracts type from meta', () {
      expect(
        const GeminiResponse(status: 20, meta: 'text/gemini; charset=utf-8', body: '')
            .mimeType,
        'text/gemini',
      );
      expect(
        const GeminiResponse(status: 20, meta: 'text/plain', body: '')
            .mimeType,
        'text/plain',
      );
    });

    test('mimeType is empty for non-success', () {
      expect(
        const GeminiResponse(status: 51, meta: 'Not found', body: '')
            .mimeType,
        '',
      );
    });

    test('isGemtext for text/gemini and empty mime', () {
      expect(
        const GeminiResponse(status: 20, meta: 'text/gemini', body: '')
            .isGemtext,
        isTrue,
      );
      expect(
        const GeminiResponse(status: 20, meta: '', body: '').isGemtext,
        isTrue,
      );
    });

    test('isGemtext false for other mime types', () {
      expect(
        const GeminiResponse(status: 20, meta: 'text/plain', body: '')
            .isGemtext,
        isFalse,
      );
      expect(
        const GeminiResponse(status: 20, meta: 'text/html', body: '')
            .isGemtext,
        isFalse,
      );
    });

    test('status categories are mutually exclusive', () {
      final success = const GeminiResponse(status: 20, meta: '', body: '');
      expect(success.isSuccess, isTrue);
      expect(success.isRedirect, isFalse);
      expect(success.isInput, isFalse);
      expect(success.isError, isFalse);

      final redirect = const GeminiResponse(status: 30, meta: '', body: '');
      expect(redirect.isSuccess, isFalse);
      expect(redirect.isRedirect, isTrue);

      final error = const GeminiResponse(status: 51, meta: '', body: '');
      expect(error.isSuccess, isFalse);
      expect(error.isError, isTrue);
    });
  });

  group('GeminiClient.fetch', () {
    test('rejects non-gemini URLs', () async {
      final response = await GeminiClient.fetch('https://example.com');
      expect(response.status, 0);
      expect(response.meta, contains('Invalid'));
    });

    test('rejects empty URL', () async {
      final response = await GeminiClient.fetch('');
      expect(response.status, 0);
      expect(response.meta, contains('Invalid'));
    });

    test('handles connection failure gracefully', () async {
      final response = await GeminiClient.fetch('gemini://127.0.0.1:19999');
      expect(response.status, 0);
      expect(response.isError, isTrue);
    });
  });
}
