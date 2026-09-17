// A TLS origin that does not need an `openssl` binary.
//
// Both https arms of BUG-014 skipped on the macOS tier and printed "openssl
// is not installed": the tier runs a built app bundle, not a shell, so a
// `Process.runSync('openssl', ...)` there finds nothing. A skipped test reads
// exactly like a test that ran, which is how the arm the whole investigation
// turns on managed to never execute. The certificate is minted in Dart here
// instead, so the only thing an arm can now depend on is the arm.
//
// The cert is self-signed and lives for a day. Nothing trusts it: the panes
// that use it answer `onReceivedServerTrustAuthRequest` with PROCEED, and the
// Dart-side clients set `badCertificateCallback`.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart' as pc;

class SelfSignedCert {
  const SelfSignedCert({required this.certPem, required this.keyPem});

  final String certPem;
  final String keyPem;

  SecurityContext serverContext() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certPem))
    ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// The certificate itself, for a caller that pins it by digest.
  Uint8List get certDer => base64.decode(
        certPem.split('\n').where((l) => !l.startsWith('-----')).join(),
      );
}

/// An RSA-2048 / SHA-256 self-signed certificate for [commonName], carrying
/// [ipAddresses] and [dnsNames] in its subjectAltName.
///
/// Key generation is a few seconds of BigInt arithmetic, so call it once per
/// suite rather than once per server.
SelfSignedCert generateSelfSignedCert({
  required String commonName,
  List<String> ipAddresses = const [],
  List<String> dnsNames = const [],
  int bits = 2048,
  Duration validFor = const Duration(days: 1),
}) {
  final pair = _rsaKeyPair(bits);
  final pub = pair.publicKey;
  final priv = pair.privateKey;

  final tbs = ASN1Sequence()
    ..add(ASN1Sequence(tag: 0xA0)..add(ASN1Integer(BigInt.from(2))))
    ..add(ASN1Integer(_serial()))
    ..add(_sha256WithRsa())
    ..add(_name(commonName))
    ..add(_validity(validFor))
    ..add(_name(commonName))
    ..add(_publicKeyInfo(pub))
    ..add(_extensions(ipAddresses: ipAddresses, dnsNames: dnsNames));

  final signer = pc.Signer('SHA-256/RSA') as pc.RSASigner
    ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(priv));
  final signature = signer.generateSignature(tbs.encodedBytes);

  final cert = ASN1Sequence()
    ..add(tbs)
    ..add(_sha256WithRsa())
    ..add(ASN1BitString(signature.bytes.toList()));

  return SelfSignedCert(
    certPem: _pem('CERTIFICATE', cert.encodedBytes),
    keyPem: _pem('RSA PRIVATE KEY', _pkcs1(priv).encodedBytes),
  );
}

pc.AsymmetricKeyPair<pc.RSAPublicKey, pc.RSAPrivateKey> _rsaKeyPair(int bits) {
  final entropy = Random.secure();
  final random = pc.FortunaRandom()
    ..seed(pc.KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (_) => entropy.nextInt(256))),
    ));
  final generator = pc.RSAKeyGenerator()
    ..init(pc.ParametersWithRandom(
      pc.RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
      random,
    ));
  final pair = generator.generateKeyPair();
  return pc.AsymmetricKeyPair(
    pair.publicKey as pc.RSAPublicKey,
    pair.privateKey as pc.RSAPrivateKey,
  );
}

BigInt _serial() {
  final entropy = Random.secure();
  var serial = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    serial = (serial << 8) | BigInt.from(entropy.nextInt(256));
  }
  return serial.abs() + BigInt.one;
}

ASN1Object _sha256WithRsa() => ASN1Sequence()
  ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
  ..add(ASN1Null());

ASN1Object _name(String commonName) {
  final attribute = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
    ..add(ASN1UTF8String(commonName));
  return ASN1Sequence()..add(ASN1Set()..add(attribute));
}

ASN1Object _validity(Duration validFor) {
  final now = DateTime.now().toUtc();
  return ASN1Sequence()
    ..add(ASN1UtcTime(now.subtract(const Duration(hours: 1))))
    ..add(ASN1UtcTime(now.add(validFor)));
}

ASN1Object _publicKeyInfo(pc.RSAPublicKey key) {
  final algorithm = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());
  final key0 = ASN1Sequence()
    ..add(ASN1Integer(key.modulus!))
    ..add(ASN1Integer(key.exponent!));
  return ASN1Sequence()
    ..add(algorithm)
    ..add(ASN1BitString(key0.encodedBytes.toList()));
}

ASN1Object _extensions({
  required List<String> ipAddresses,
  required List<String> dnsNames,
}) {
  final names = ASN1Sequence();
  for (final dns in dnsNames) {
    names.add(ASN1OctetString(dns, tag: 0x82));
  }
  for (final ip in ipAddresses) {
    names.add(ASN1OctetString(
      Uint8List.fromList(InternetAddress(ip).rawAddress),
      tag: 0x87,
    ));
  }

  final basicConstraints = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.29.19'))
    ..add(ASN1Boolean(true))
    ..add(ASN1OctetString(
      (ASN1Sequence()..add(ASN1Boolean(true))).encodedBytes,
    ));
  final subjectAltName = ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('2.5.29.17'))
    ..add(ASN1OctetString(names.encodedBytes));

  final all = ASN1Sequence()
    ..add(basicConstraints)
    ..add(subjectAltName);
  return ASN1Sequence(tag: 0xA3)..add(all);
}

ASN1Object _pkcs1(pc.RSAPrivateKey key) {
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  return ASN1Sequence()
    ..add(ASN1Integer(BigInt.zero))
    ..add(ASN1Integer(key.modulus!))
    ..add(ASN1Integer(key.publicExponent!))
    ..add(ASN1Integer(d))
    ..add(ASN1Integer(p))
    ..add(ASN1Integer(q))
    ..add(ASN1Integer(d % (p - BigInt.one)))
    ..add(ASN1Integer(d % (q - BigInt.one)))
    ..add(ASN1Integer(q.modInverse(p)));
}

String _pem(String label, Uint8List der) {
  final body = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < body.length; i += 64) {
    lines.add(body.substring(i, min(i + 64, body.length)));
  }
  return '-----BEGIN $label-----\n${lines.join("\n")}\n-----END $label-----\n';
}
