import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 fingerprint of a `dart:io` X509Certificate (used by
/// `HttpClient.badCertificateCallback`).
///
/// Split out of [TrustedHostsService] so that service stays free of
/// `dart:io`: it is imported by the trusted-certificates screen, and a
/// `dart:io` import there keeps the screen off the web target.
String fingerprintFromX509(X509Certificate cert) =>
    sha256.convert(cert.der).toString();
