import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

void main() {
  group('Title Extraction Tests', () {
    test('Extract title from HTML fixture', () {
      final html = '''
<!DOCTYPE html>
<html>
<head>
  <title>MLflow - Experiment Tracking</title>
</head>
<body>
  <h1>Test</h1>
</body>
</html>
''';
      
      html_dom.Document document = html_parser.parse(html);
      final titleElement = document.querySelector('title');
      
      expect(titleElement, isNotNull);
      expect(titleElement!.text, 'MLflow - Experiment Tracking');
      expect(titleElement.text.trim(), 'MLflow - Experiment Tracking');
    });

    test('Extract title from fixture file', () {
      final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Test Page Title - WebSpace App</title>
</head>
<body>
    <h1>Title Extraction Test</h1>
</body>
</html>
''';
      
      html_dom.Document document = html_parser.parse(html);
      final titleElement = document.querySelector('title');
      
      expect(titleElement, isNotNull);
      expect(titleElement!.text.trim(), 'Test Page Title - WebSpace App');
    });

    test('Handle missing title gracefully', () {
      final html = '''
<!DOCTYPE html>
<html>
<head>
</head>
<body>
  <h1>No Title</h1>
</body>
</html>
''';
      
      html_dom.Document document = html_parser.parse(html);
      final titleElement = document.querySelector('title');
      
      expect(titleElement, isNull);
    });

    test('Handle empty title', () {
      final html = '''
<!DOCTYPE html>
<html>
<head>
  <title></title>
</head>
<body>
  <h1>Empty Title</h1>
</body>
</html>
''';
      
      html_dom.Document document = html_parser.parse(html);
      final titleElement = document.querySelector('title');
      
      expect(titleElement, isNotNull);
      expect(titleElement!.text.trim(), isEmpty);
    });
  });
}
