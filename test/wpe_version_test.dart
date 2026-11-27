import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/wpe_version.dart';

void main() {
  test('WPE 2.54.0 and 2.54.1 read disableAnimations inverted (A11Y-011)', () {
    for (final version in ['2.54.0', '2.54.1']) {
      expect(wpeInvertsDisableAnimations(version), isTrue, reason: version);
      expect(wpeDisableAnimations(reduced: true, version: version), isFalse,
          reason: version);
      expect(wpeDisableAnimations(reduced: false, version: version), isTrue,
          reason: version);
    }
  });

  test('every other WPE, or one that said nothing, reads it as sent (A11Y-011)',
      () {
    for (final version in [
      '2.52.0',
      '2.52.3',
      '2.54.2',
      '2.56.0',
      '2.54',
      null,
      '',
      'two.fifty-four',
    ]) {
      expect(wpeInvertsDisableAnimations(version), isFalse, reason: version);
      expect(wpeDisableAnimations(reduced: true, version: version), isTrue,
          reason: version);
      expect(wpeDisableAnimations(reduced: false, version: version), isFalse,
          reason: version);
    }
  });
}
