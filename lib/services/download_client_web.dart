import 'package:http/http.dart' as http;

/// Downloads do not run in the design gallery; the browser client exists only
/// so the engine's pure logic (filename derivation, cookie headers, data URIs)
/// stays reachable from a web compile.
http.Client createDirectDownloadClient() => http.Client();
