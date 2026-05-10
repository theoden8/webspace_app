import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/gemini_renderer.dart';

void main() {
  group('GeminiRenderer.render', () {
    test('renders plain text as paragraphs', () {
      final html = GeminiRenderer.render('Hello world', 'gemini://example.com');
      expect(html, contains('<p>Hello world</p>'));
    });

    test('renders headings', () {
      final input = '# Heading 1\n## Heading 2\n### Heading 3';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<h1>Heading 1</h1>'));
      expect(html, contains('<h2>Heading 2</h2>'));
      expect(html, contains('<h3>Heading 3</h3>'));
    });

    test('renders links with labels', () {
      final input = '=> gemini://other.com/page Click here';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('href="gemini://other.com/page"'));
      expect(html, contains('Click here'));
    });

    test('renders links without labels using URL as text', () {
      final input = '=> gemini://other.com/page';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('href="gemini://other.com/page"'));
      expect(html, contains('>gemini://other.com/page</a>'));
    });

    test('resolves relative links against current URL', () {
      final input = '=> /other-page Other Page';
      final html = GeminiRenderer.render(input, 'gemini://example.com/current');
      expect(html, contains('href="gemini://example.com/other-page"'));
    });

    test('marks non-gemini links as external', () {
      final input = '=> https://example.com Web Link';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('href="https://example.com"'));
      expect(html, contains('&#x2197;'));
    });

    test('does not mark gemini links as external', () {
      final input = '=> gemini://example.com Gemini Link';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, isNot(contains('&#x2197;')));
    });

    test('renders unordered lists', () {
      final input = '* Item one\n* Item two\n* Item three';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<ul>'));
      expect(html, contains('<li>Item one</li>'));
      expect(html, contains('<li>Item two</li>'));
      expect(html, contains('<li>Item three</li>'));
      expect(html, contains('</ul>'));
    });

    test('closes list before non-list content', () {
      final input = '* Item\nParagraph after list';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('</ul>'));
      expect(html, contains('<p>Paragraph after list</p>'));
      final ulEnd = html.indexOf('</ul>');
      final pStart = html.indexOf('<p>Paragraph after list</p>');
      expect(ulEnd, lessThan(pStart));
    });

    test('renders preformatted blocks', () {
      final input = '```code\nfn main() {\n  println!("hi");\n}\n```';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<pre aria-label="code">'));
      expect(html, contains('fn main()'));
      expect(html, contains('</pre>'));
    });

    test('renders preformatted blocks without alt text', () {
      final input = '```\nplain preformatted\n```';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<pre>'));
      expect(html, contains('plain preformatted'));
    });

    test('renders blockquotes', () {
      final input = '> This is a quote';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<blockquote>This is a quote</blockquote>'));
    });

    test('renders empty lines as breaks', () {
      final input = 'Before\n\nAfter';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<br>'));
    });

    test('escapes HTML entities in text', () {
      final input = 'Use <script> & "quotes"';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('&lt;script&gt;'));
      expect(html, contains('&amp;'));
      expect(html, contains('&quot;quotes&quot;'));
      expect(html, isNot(contains('<script>')));
    });

    test('escapes HTML entities in preformatted blocks', () {
      final input = '```\n<div class="x">&amp;</div>\n```';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('&lt;div'));
      expect(html, isNot(contains('<div class=')));
    });

    test('escapes HTML entities in link labels', () {
      final input = '=> gemini://x.com Label with <html>';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('&lt;html&gt;'));
    });

    test('produces valid HTML document structure', () {
      final html = GeminiRenderer.render('Hello', 'gemini://example.com');
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<html>'));
      expect(html, contains('<head>'));
      expect(html, contains('<meta charset="utf-8">'));
      expect(html, contains('<body>'));
      expect(html, contains('</html>'));
    });

    test('dark mode uses dark colors', () {
      final html = GeminiRenderer.render('Hello', 'gemini://example.com',
          dark: true);
      expect(html, contains('#1e1e1e'));
      expect(html, contains('#d4d4d4'));
    });

    test('light mode uses light colors', () {
      final html = GeminiRenderer.render('Hello', 'gemini://example.com',
          dark: false);
      expect(html, contains('#fafafa'));
    });

    test('handles empty link line', () {
      final input = '=>';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<br>'));
    });

    test('handles link with only spaces after arrow', () {
      final input = '=>   ';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<br>'));
    });

    test('handles empty input', () {
      final html = GeminiRenderer.render('', 'gemini://example.com');
      expect(html, contains('<body>'));
    });

    test('unclosed preformatted block is closed at end', () {
      final input = '```\nunclosed block';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<pre>'));
      expect(html, contains('</pre>'));
    });

    test('unclosed list is closed at end', () {
      final input = '* orphan item';
      final html = GeminiRenderer.render(input, 'gemini://example.com');
      expect(html, contains('<ul>'));
      expect(html, contains('</ul>'));
    });
  });

  group('GeminiRenderer.renderError', () {
    test('shows status and message', () {
      final html = GeminiRenderer.renderError(51, 'Not found',
          'gemini://example.com/missing');
      expect(html, contains('51'));
      expect(html, contains('Not found'));
      expect(html, contains('gemini://example.com/missing'));
    });

    test('handles zero status for network errors', () {
      final html = GeminiRenderer.renderError(0, 'Connection timeout',
          'gemini://example.com');
      expect(html, contains('Connection timeout'));
    });

    test('escapes HTML in error messages', () {
      final html = GeminiRenderer.renderError(0, '<script>alert(1)</script>',
          'gemini://example.com');
      expect(html, contains('&lt;script&gt;'));
      expect(html, isNot(contains('<script>alert')));
    });
  });

  group('GeminiRenderer.renderLoading', () {
    test('shows URL in loading page', () {
      final html = GeminiRenderer.renderLoading('gemini://example.com');
      expect(html, contains('gemini://example.com'));
    });

    test('escapes HTML in URL', () {
      final html = GeminiRenderer.renderLoading('gemini://example.com/<path>');
      expect(html, contains('&lt;path&gt;'));
    });
  });
}
