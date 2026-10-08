import 'dart:convert';


/// HTML rendered when a file-import site has no cached HTML available
/// (incognito session, post-upgrade cache wipe, …). Loaded via
/// `InAppWebViewInitialData` so chromium never tries to fetch the synthetic
/// `file:///<filename>` URL — that would surface as `ERR_INVALID_URL` /
/// `ERR_FILE_NOT_FOUND` since no real file exists on disk for the import.
String buildFileImportFallbackHtml(String initialUrl) {
  // initialUrl is `file:///filename.html` for new imports and
  // `file://filename.html` (or `file://filename.html/`) for legacy data
  // that hasn't been migrated yet. Strip the scheme + leading slashes
  // for display.
  final stripped = initialUrl.replaceFirst(RegExp(r'^file:/+'), '');
  final fileName = stripped.endsWith('/')
      ? stripped.substring(0, stripped.length - 1)
      : stripped;
  final escapedName = htmlEscape.convert(fileName);
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Imported file unavailable</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    max-width: 32em;
    margin: 3em auto;
    padding: 0 1em;
    line-height: 1.5;
  }
  h1 { font-size: 1.4em; }
  code {
    background: rgba(127,127,127,0.18);
    padding: 0.1em 0.35em;
    border-radius: 3px;
  }
  p { color: rgba(0,0,0,0.78); }
  @media (prefers-color-scheme: dark) {
    p { color: rgba(255,255,255,0.78); }
  }
</style>
</head>
<body>
<h1>Imported file unavailable</h1>
<p>The contents of <code>$escapedName</code> were imported as a local file
and aren't cached on this device any more (incognito sessions don't
persist, and the cache is cleared on app upgrade).</p>
<p>Re-import the file from the "Add new site" screen to view it again.</p>
</body>
</html>
''';
}

/// The document a file-import webview renders in place of its URL
/// (IMPORT-005, BUG-017).
///
/// The import's `file:///<name>` URL is a synthetic handle with nothing
/// behind it, so the engine must never be asked to fetch it. The controller
/// renders [html] instead when a load targets [url] (the deferred first load
/// of LEAK-003, the resume reissue of PAUSE-022) and, on WebKit, on every
/// reload: `FrameLoader::reload` re-requests the document's URL and drops the
/// bytes the page was rendered from, fails provisionally, and never reaches
/// the `onLoadStop` that ends the pull-to-refresh indicator and the loading
/// bar. Chromium keeps those bytes on the navigation entry, so its reload
/// stays native there; re-rendering would push a history entry per refresh.
class FileImportDocument {
  const FileImportDocument({required this.url, required this.html});

  /// Null unless [initialUrl] is a file import. [initialHtml] is the stored
  /// import; the "unavailable" page stands in when it is missing.
  static FileImportDocument? of({
    required String initialUrl,
    String? initialHtml,
  }) {
    if (!initialUrl.startsWith('file://')) return null;
    return FileImportDocument(
      url: initialUrl,
      html: initialHtml ?? buildFileImportFallbackHtml(initialUrl),
    );
  }

  final String url;
  final String html;

  bool isLoadOf(String target) =>
      _withoutFragment(target) == _withoutFragment(url);

  static bool rendersOnReload({required bool isAndroid}) => !isAndroid;

  static String _withoutFragment(String u) {
    final i = u.indexOf('#');
    return i < 0 ? u : u.substring(0, i);
  }
}
