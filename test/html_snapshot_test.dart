import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/html_snapshot.dart';

void main() {
  group('awaitOnlineForLiveSwap', () {
    late List<Duration> waited;

    Future<void> wait(Duration d) async => waited.add(d);

    setUp(() => waited = []);

    test('swaps on the first probe when online', () async {
      var probes = 0;
      final ok = await awaitOnlineForLiveSwap(
        isOnline: () async {
          probes++;
          return true;
        },
        stillWanted: () => true,
        wait: wait,
      );
      expect(ok, isTrue);
      expect(probes, 1);
      expect(waited, isEmpty);
    });

    test('keeps probing until the network comes back', () async {
      final answers = [false, false, true];
      final ok = await awaitOnlineForLiveSwap(
        isOnline: () async => answers.removeAt(0),
        stillWanted: () => true,
        wait: wait,
      );
      expect(ok, isTrue);
      expect(answers, isEmpty);
      expect(waited, liveSwapProbeDelays.sublist(1, 3));
    });

    test('gives up after the last probe finds it offline', () async {
      var probes = 0;
      final ok = await awaitOnlineForLiveSwap(
        isOnline: () async {
          probes++;
          return false;
        },
        stillWanted: () => true,
        wait: wait,
      );
      expect(ok, isFalse);
      expect(probes, liveSwapProbeDelays.length);
    });

    test('a navigation during a wait cancels the swap', () async {
      var navigated = false;
      var probes = 0;
      final ok = await awaitOnlineForLiveSwap(
        isOnline: () async {
          probes++;
          return false;
        },
        stillWanted: () => !navigated,
        wait: (d) async {
          waited.add(d);
          navigated = true;
        },
      );
      expect(ok, isFalse);
      expect(probes, 1);
    });

    test('a navigation during the probe that finds the network cancels it',
        () async {
      var navigated = false;
      final ok = await awaitOnlineForLiveSwap(
        isOnline: () async {
          navigated = true;
          return true;
        },
        stillWanted: () => !navigated,
        wait: wait,
      );
      expect(ok, isFalse);
    });
  });
}
