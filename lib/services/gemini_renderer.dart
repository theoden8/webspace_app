import 'dart:convert';

class GeminiRenderer {
  static String render(String gemtext, String currentUrl, {bool dark = false}) {
    final lines = const LineSplitter().convert(gemtext);
    final buffer = StringBuffer();
    var inPre = false;
    var inList = false;

    for (final line in lines) {
      if (line.startsWith('```')) {
        if (inList) {
          buffer.writeln('</ul>');
          inList = false;
        }
        inPre = !inPre;
        if (inPre) {
          final alt = line.length > 3 ? _esc(line.substring(3).trim()) : '';
          buffer.writeln(alt.isNotEmpty
              ? '<pre aria-label="$alt">'
              : '<pre>');
        } else {
          buffer.writeln('</pre>');
        }
        continue;
      }

      if (inPre) {
        buffer.writeln(_esc(line));
        continue;
      }

      if (line.startsWith('* ')) {
        if (!inList) {
          buffer.writeln('<ul>');
          inList = true;
        }
        buffer.writeln('<li>${_esc(line.substring(2))}</li>');
        continue;
      }
      if (inList) {
        buffer.writeln('</ul>');
        inList = false;
      }

      if (line.startsWith('=>')) {
        buffer.writeln(_renderLink(line, currentUrl));
      } else if (line.startsWith('### ')) {
        buffer.writeln('<h3>${_esc(line.substring(4))}</h3>');
      } else if (line.startsWith('## ')) {
        buffer.writeln('<h2>${_esc(line.substring(3))}</h2>');
      } else if (line.startsWith('# ')) {
        buffer.writeln('<h1>${_esc(line.substring(2))}</h1>');
      } else if (line.startsWith('>')) {
        final text = line.length > 1 ? line.substring(1).trimLeft() : '';
        buffer.writeln('<blockquote>${_esc(text)}</blockquote>');
      } else if (line.trim().isEmpty) {
        buffer.writeln('<br>');
      } else {
        buffer.writeln('<p>${_esc(line)}</p>');
      }
    }

    if (inList) buffer.writeln('</ul>');
    if (inPre) buffer.writeln('</pre>');

    return _wrapHtml(buffer.toString(), dark: dark);
  }

  static String renderError(int status, String meta, String url,
      {bool dark = false}) {
    final body = StringBuffer();
    body.writeln('<h1>Gemini Error</h1>');
    body.writeln('<p><strong>URL:</strong> ${_esc(url)}</p>');
    if (status > 0) {
      body.writeln('<p><strong>Status:</strong> $status</p>');
    }
    body.writeln('<p><strong>Message:</strong> ${_esc(meta)}</p>');
    return _wrapHtml(body.toString(), dark: dark);
  }

  static String renderLoading(String url, {bool dark = false}) {
    return _wrapHtml(
      '<p>Loading ${_esc(url)}...</p>',
      dark: dark,
    );
  }

  static String _renderLink(String line, String currentUrl) {
    final content = line.substring(2).trimLeft();
    if (content.isEmpty) return '<br>';

    final spaceIndex = content.indexOf(RegExp(r'\s'));
    String href;
    String label;
    if (spaceIndex < 0) {
      href = content;
      label = content;
    } else {
      href = content.substring(0, spaceIndex);
      label = content.substring(spaceIndex).trim();
      if (label.isEmpty) label = href;
    }

    final resolved = _resolveUrl(href, currentUrl);
    final isExternal = !resolved.startsWith('gemini://');
    final suffix = isExternal ? ' &#x2197;' : '';
    return '<p class="link"><a href="${_escAttr(resolved)}">'
        '${_esc(label)}$suffix</a></p>';
  }

  static String _resolveUrl(String href, String currentUrl) {
    final parsed = Uri.tryParse(href);
    if (parsed != null && parsed.hasScheme) return href;
    final base = Uri.tryParse(currentUrl);
    if (base == null) return href;
    return base.resolve(href).toString();
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _escAttr(String s) => _esc(s).replaceAll("'", '&#x27;');

  static String _wrapHtml(String body, {required bool dark}) {
    final bg = dark ? '#1e1e1e' : '#fafafa';
    final fg = dark ? '#d4d4d4' : '#1e1e1e';
    final link = dark ? '#6cb6ff' : '#0969da';
    final pre = dark ? '#2d2d2d' : '#f0f0f0';
    final quote = dark ? '#8b949e' : '#656d76';
    final border = dark ? '#444' : '#ccc';
    return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{background:$bg;color:$fg;font-family:system-ui,sans-serif;
line-height:1.6;max-width:720px;margin:0 auto;padding:16px;word-wrap:break-word}
a{color:$link;text-decoration:none}
a:hover{text-decoration:underline}
h1,h2,h3{margin:1em 0 0.5em}
pre{background:$pre;padding:12px;overflow-x:auto;border-radius:4px;
font-size:14px;line-height:1.4}
blockquote{border-left:3px solid $border;color:$quote;margin:0.5em 0;
padding:0.25em 0 0.25em 12px}
ul{padding-left:24px}
p{margin:0.4em 0}
.link{margin:0.2em 0}
.link a::before{content:"=> ";opacity:0.5}
</style>
</head>
<body>
$body
</body>
</html>''';
  }
}
