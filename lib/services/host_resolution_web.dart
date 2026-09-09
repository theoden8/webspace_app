// Web half of the host-resolution seam, used by the design entrypoints.
//
// A browser exposes no resolver, so this reports "cannot answer" instead of
// guessing. The web target does not run the webview and therefore has no page
// JS to drive an outbound fetch in the first place.

Future<List<String>?> lookupHostAddresses(String host) async => null;
