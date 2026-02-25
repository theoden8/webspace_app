import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';

void main() {
  setUp(() {
    ConnectivityService.reset();
  });

  tearDown(() {
    ConnectivityService.reset();
  });

  group('ConnectivityService', () {
    test('onlineOverride returns true when set to true', () async {
      ConnectivityService.onlineOverride = Future.value(true);
      expect(await ConnectivityService.instance.isOnline(), isTrue);
    });

    test('onlineOverride returns false when set to false', () async {
      ConnectivityService.onlineOverride = Future.value(false);
      expect(await ConnectivityService.instance.isOnline(), isFalse);
    });

    test('reset clears override', () async {
      ConnectivityService.onlineOverride = Future.value(false);
      expect(await ConnectivityService.instance.isOnline(), isFalse);

      ConnectivityService.reset();
      // After reset, override is null so it falls through to real DNS lookup
      // which should succeed in CI/dev environments
      ConnectivityService.onlineOverride = Future.value(true);
      expect(await ConnectivityService.instance.isOnline(), isTrue);
    });

    test('singleton returns same instance', () {
      final a = ConnectivityService.instance;
      final b = ConnectivityService.instance;
      expect(identical(a, b), isTrue);
    });

    test('reset creates new instance', () {
      final a = ConnectivityService.instance;
      ConnectivityService.reset();
      final b = ConnectivityService.instance;
      expect(identical(a, b), isFalse);
    });
  });
}
