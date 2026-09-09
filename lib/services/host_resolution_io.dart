// dart:io half of the host-resolution seam.

import 'dart:io';

/// Resolve [host] to its numeric addresses. Throws [SocketException] when the
/// name does not resolve, which the caller reads as "no answer" rather than
/// "public".
Future<List<String>?> lookupHostAddresses(String host) async {
  final addresses = await InternetAddress.lookup(host);
  return addresses.map((a) => a.address).toList();
}
