import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/platform/apple_os_floor.dart';

void main() {
  group('appleOsMeetsFloor (SEC-001)', () {
    bool meets(String version, {required bool isIOS}) =>
        appleOsMeetsFloor(version, isIOS: isIOS, floor: AppleOsFloor.stores);

    test('iOS below 17 is under the container/proxy floor', () {
      expect(meets('Version 16.7.2 (Build 20H115)', isIOS: true), isFalse);
      expect(meets('Version 15.0 (Build 19A346)', isIOS: true), isFalse);
    });

    test('iOS 17 and later meet the floor', () {
      expect(meets('Version 17.0.3 (Build 21A360)', isIOS: true), isTrue);
      expect(meets('Version 26.0 (Build 23A340)', isIOS: true), isTrue);
    });

    test('macOS below 14 is under the floor, 14 and later meet it', () {
      expect(meets('Version 13.6.1 (Build 22G313)', isIOS: false), isFalse);
      expect(meets('Version 10.15.7 (Build 19H2)', isIOS: false), isFalse);
      expect(meets('Version 14.1 (Build 23B74)', isIOS: false), isTrue);
    });

    test('an unparseable version counts as below the floor', () {
      expect(meets('', isIOS: true), isFalse);
      expect(meets('unknown', isIOS: false), isFalse);
    });
  });

  group('appleOsMeetsFloor for Lockdown Mode (ETP-032)', () {
    bool meets(String version, {required bool isIOS}) => appleOsMeetsFloor(
        version, isIOS: isIOS, floor: AppleOsFloor.lockdownMode);

    test('iOS 16 and macOS 13 are the floor', () {
      expect(meets('Version 15.8 (Build 19H370)', isIOS: true), isFalse);
      expect(meets('Version 16.0 (Build 20A362)', isIOS: true), isTrue);
      expect(meets('Version 12.7.6 (Build 21H1320)', isIOS: false), isFalse);
      expect(meets('Version 13.0 (Build 22A380)', isIOS: false), isTrue);
    });
  });

  group('appleOsMeetsFloor for web extensions', () {
    bool meets(String version, {required bool isIOS}) => appleOsMeetsFloor(
        version, isIOS: isIOS, floor: AppleOsFloor.webExtensions);

    test('iOS 18.4 and macOS 15.4 are the floor, minor version included', () {
      expect(meets('Version 18.3.2 (Build 22D82)', isIOS: true), isFalse);
      expect(meets('Version 18 (Build 22A3354)', isIOS: true), isFalse);
      expect(meets('Version 18.4 (Build 22E240)', isIOS: true), isTrue);
      expect(meets('Version 18.10 (Build 22X1)', isIOS: true), isTrue);
      expect(meets('Version 26.0 (Build 23A340)', isIOS: true), isTrue);
      expect(meets('Version 15.3.2 (Build 24D81)', isIOS: false), isFalse);
      expect(meets('Version 15.4.1 (Build 24E263)', isIOS: false), isTrue);
      expect(meets('Version 26.1 (Build 25B78)', isIOS: false), isTrue);
    });
  });
}
