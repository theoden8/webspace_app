/// Returns true if [url] already starts with a URL scheme such as
/// `http://`, `https://`, `chrome://`, `about:`, `file://`, `javascript:`,
/// `data:`, or `mailto:`. Used to avoid prepending `https://` to URLs the
/// user already qualified with a scheme.
///
/// A URL has a scheme if:
///   - it contains `://` after a leading alpha/digit/+/- scheme identifier, OR
///   - it starts with a known authority-less scheme followed by `:`
///     (`about:`, `javascript:`, `data:`, `mailto:`, `tel:`, `view-source:`).
///
/// This deliberately excludes bare `host:port` strings like `localhost:8080`
/// or `192.168.1.1:3000` so they still get `https://` prepended.
bool hasUrlScheme(String url) {
  if (_authoritySchemeRegex.hasMatch(url)) return true;
  return _authorityLessSchemeRegex.hasMatch(url);
}

final RegExp _authoritySchemeRegex =
    RegExp(r'^[a-zA-Z][a-zA-Z0-9+\-]*://');
final RegExp _authorityLessSchemeRegex =
    RegExp(r'^(about|javascript|data|mailto|tel|view-source):');

/// If [url] has no scheme, prepends `https://`. Otherwise returns [url]
/// unchanged so schemes like `chrome://` are preserved.
String ensureUrlScheme(String url) {
  return hasUrlScheme(url) ? url : 'https://$url';
}
