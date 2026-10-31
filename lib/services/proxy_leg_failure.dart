/// A load that failed between the webview and its proxy rather than at the
/// site. Android's WebView files these under its proxy-authentication and
/// TLS-handshake buckets (`WebResourceErrorType`), so only Chromium's error
/// name in the description says which leg failed.
enum ProxyLegFailure {
  /// Nothing answered at the proxy's address.
  unreachable('ERR_PROXY_CONNECTION_FAILED'),

  /// The proxy answered but opened no tunnel to the site.
  tunnel('ERR_TUNNEL_CONNECTION_FAILED');

  const ProxyLegFailure(this.netError);

  /// Chromium's name for it, reported as `net::<name>`.
  final String netError;

  /// The failure [description] reports, or null for any other error.
  static ProxyLegFailure? of(String description) {
    for (final failure in values) {
      if (description.trim() == 'net::${failure.netError}') return failure;
    }
    return null;
  }
}
