/// Returns true if [url] already starts with a URL scheme such as
/// `http://`, `https://`, `chrome://`, `about:`, `file://`, `javascript:`,
/// `data:`, `mailto:`, etc. Used to avoid prepending `https://` to URLs the
/// user already qualified with a scheme.
///
/// The scheme is `[a-zA-Z][a-zA-Z0-9+-]*` followed by `:`. Dots are excluded
/// from the scheme to keep `example.com:8080` classified as a host:port, not a
/// scheme.
bool hasUrlScheme(String url) {
  return _schemeRegex.hasMatch(url);
}

final RegExp _schemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+\-]*:');

/// If [url] has no scheme, prepends `https://`. Otherwise returns [url]
/// unchanged so schemes like `chrome://` are preserved.
String ensureUrlScheme(String url) {
  return hasUrlScheme(url) ? url : 'https://$url';
}
