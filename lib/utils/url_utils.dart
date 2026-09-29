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

/// Whether text typed in the URL bar names an address rather than words to
/// search for (LIR-033): anything with a scheme, or one token that is
/// `localhost`, an IP address, a `host:port`, or a dotted host ending in a
/// top-level label of letters. A bare word, anything with a space, and an
/// email address search instead.
bool looksLikeAddress(String input) {
  final t = input.trim();
  if (t.isEmpty) return false;
  if (hasUrlScheme(t)) return true;
  if (_whitespace.hasMatch(t)) return false;
  final authority = t.split(_authorityEnd).first;
  if (authority.contains('@')) return false;
  if (authority.startsWith('[')) return authority.contains(']');
  final colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    final host = authority.substring(0, colon);
    return _port.hasMatch(authority.substring(colon + 1)) &&
        host.isNotEmpty &&
        host.split('.').every(_hostLabel.hasMatch);
  }
  final host = authority.toLowerCase();
  if (host == 'localhost' || _ipv4.hasMatch(host)) return true;
  final labels = host.split('.');
  if (labels.length < 2 || !labels.every(_hostLabel.hasMatch)) return false;
  final tld = labels.last;
  return _tld.hasMatch(tld) || tld.startsWith('xn--');
}

final RegExp _whitespace = RegExp(r'\s');
final RegExp _authorityEnd = RegExp(r'[/?#]');
final RegExp _port = RegExp(r'^\d{1,5}$');
final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _hostLabel = RegExp(r'^[\p{L}\p{N}-]+$', unicode: true);
final RegExp _tld = RegExp(r'^\p{L}{2,63}$', unicode: true);

/// If [url] has no scheme, prepends `https://`. Otherwise returns [url]
/// unchanged so schemes like `chrome://` are preserved.
String ensureUrlScheme(String url) {
  return hasUrlScheme(url) ? url : 'https://$url';
}

/// Migrates legacy file-import URLs from `file://filename.html` to
/// `file:///filename.html`. The two-slash form parses with `filename.html`
/// as the URL host and an empty path, which chromium rejects with
/// ERR_INVALID_URL on any direct load (incognito, post-upgrade cache wipe).
/// The three-slash form has an empty authority and a real path, so it
/// round-trips through Uri parsing without surprises.
///
/// Idempotent: a URL that already starts with `file:///` (or any non-file
/// scheme) is returned unchanged.
String migrateLegacyFileImportUrl(String url) {
  if (!url.startsWith('file://') || url.startsWith('file:///')) {
    return url;
  }
  return 'file:///${url.substring('file://'.length)}';
}
