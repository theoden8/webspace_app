import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/apple_os_floor.dart';

void main() {
  group('appleOsMeetsFloor (SEC-001)', () {
    test('iOS below 17 is under the container/proxy floor', () {
      expect(appleOsMeetsFloor('Version 16.7.2 (Build 20H115)', isIOS: true),
          isFalse);
      expect(appleOsMeetsFloor('Version 15.0 (Build 19A346)', isIOS: true),
          isFalse);
    });

    test('iOS 17 and later meet the floor', () {
      expect(appleOsMeetsFloor('Version 17.0.3 (Build 21A360)', isIOS: true),
          isTrue);
      expect(appleOsMeetsFloor('Version 26.0 (Build 23A340)', isIOS: true),
          isTrue);
    });

    test('macOS below 14 is under the floor, 14 and later meet it', () {
      expect(appleOsMeetsFloor('Version 13.6.1 (Build 22G313)', isIOS: false),
          isFalse);
      expect(appleOsMeetsFloor('Version 10.15.7 (Build 19H2)', isIOS: false),
          isFalse);
      expect(appleOsMeetsFloor('Version 14.1 (Build 23B74)', isIOS: false),
          isTrue);
    });

    test('an unparseable version counts as below the floor', () {
      expect(appleOsMeetsFloor('', isIOS: true), isFalse);
      expect(appleOsMeetsFloor('unknown', isIOS: false), isFalse);
    });
  });
}
