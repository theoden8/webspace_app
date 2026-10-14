/// What `ProxyManager` throws when the rule a site's proxy needs is not in
/// force, because it cannot be made or the platform did not take it: going
/// direct instead would leak the device IP, so the caller fails closed.
final class ProxyRefused implements Exception {
  const ProxyRefused(this.message);

  final String message;

  @override
  String toString() => 'ProxyRefused: $message';
}
