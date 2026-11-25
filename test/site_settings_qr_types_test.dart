import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/web_view_model.dart';

/// A hand-made QR that puts a value of the wrong type in any key a QR
/// carries (QR-007): the receiver reads that field as absent, as a
/// well-typed QR without the key would leave it, and nothing throws.
void main() {
  const home = 'https://example.com';
  // A value of each JSON type; every key takes at most one of them.
  const wrongs = <Object?>['abc', 42, -1.5, true, <String, Object?>{}, <Object?>[]];

  Map<String, dynamic> received(Map<String, dynamic> payload) {
    final decoded = SiteSettingsQrCodec.decode(SiteSettingsQrCodec.encode(payload));
    expect(decoded, isNotNull, reason: 'a payload with initUrl decodes');
    return WebViewModel.fromJson(
      SiteSettingsQrCodec.hydrateForFromJson(decoded!),
      stateSetterF: null,
    ).toJson();
  }

  test('a wrong-typed field in a QR reads as absent, for every key a QR '
      'carries (QR-007)', () {
    final plain = received({'initUrl': home});
    final keys = SiteSettingsQrCodec.includedKeys.difference({'initUrl'});
    expect(keys, isNotEmpty);
    for (final key in keys) {
      for (final wrong in wrongs) {
        final Map<String, dynamic> site;
        try {
          site = received({'initUrl': home, key: wrong});
        } on TypeError catch (e) {
          fail('"$key": ${wrong.runtimeType} threw $e');
        }
        expect(site['initUrl'], home);
        // A value of the key's type is taken (a zoom clamps it); any other
        // leaves the field as a QR without the key does.
        if (jsonEncode(site[key]) != jsonEncode(plain[key])) {
          expect(_kind(site[key]), _kind(wrong), reason: '"$key": $wrong');
        }
      }
    }
  });
}

/// A JSON value's kind: what a reader that takes the value has to match.
String _kind(Object? v) => switch (v) {
  num() => 'number',
  String() => 'string',
  bool() => 'bool',
  Map() => 'object',
  List() => 'array',
  _ => 'null',
};
