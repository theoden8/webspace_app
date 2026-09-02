import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/pull_to_refresh_gate.dart';

class FakeRefreshControl implements RefreshControl {
  final List<bool> enabledCalls = [];
  int endRefreshingCalls = 0;

  @override
  Future<void> setEnabled(bool enabled) async => enabledCalls.add(enabled);

  @override
  Future<void> endRefreshing() async => endRefreshingCalls++;
}

void main() {
  group('PullToRefreshGate (NAV-006 multi-touch)', () {
    late FakeRefreshControl control;
    late DateTime clock;
    late PullToRefreshGate gate;

    setUp(() {
      control = FakeRefreshControl();
      clock = DateTime(2026, 1, 1);
      gate = PullToRefreshGate.forControl(control, now: () => clock);
    });

    // The same entry point `PullToRefreshGate.create` hands the controller.
    Future<bool> refresh() async {
      var ran = false;
      await gate.runRefresh(() async => ran = true);
      return ran;
    }

    test('a single-finger drag leaves the control alone', () async {
      gate.onPointerDown(1);
      expect(gate.isEnabled, isTrue);
      expect(await refresh(), isTrue);
      gate.onPointerUp(1);
      expect(control.enabledCalls, isEmpty);
    });

    test('a second pointer disables the control', () async {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      expect(control.enabledCalls, [false]);
      expect(gate.isEnabled, isFalse);
    });

    test('a third pointer does not re-send the disable', () {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerDown(3);
      expect(control.enabledCalls, [false]);
    });

    test('lifting one finger of a pinch keeps the control disabled', () {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerUp(2);
      expect(control.enabledCalls, [false]);
      expect(gate.isEnabled, isFalse);
    });

    test('the control comes back once every finger lifts', () {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerUp(1);
      gate.onPointerUp(2);
      expect(control.enabledCalls, [false, true]);
      expect(gate.isEnabled, isTrue);
    });

    test('a cancelled pointer counts as lifted', () {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      // The factory routes onPointerCancel to onPointerUp.
      gate.onPointerUp(1);
      gate.onPointerUp(2);
      expect(gate.isEnabled, isTrue);
    });

    test('a refresh mid-pinch is swallowed', () async {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      expect(await refresh(), isFalse);
      expect(control.endRefreshingCalls, 1);
    });

    test('a refresh that beat the disable by a hair is swallowed', () async {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerUp(1);
      gate.onPointerUp(2);
      clock = clock.add(const Duration(milliseconds: 100));
      expect(await refresh(), isFalse);
      expect(control.endRefreshingCalls, 1);
    });

    test('a deliberate pull after the pinch still refreshes', () async {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerUp(1);
      gate.onPointerUp(2);
      clock = clock.add(const Duration(seconds: 1));
      gate.onPointerDown(3);
      expect(await refresh(), isTrue);
      expect(control.endRefreshingCalls, 0);
    });

    test('an unmatched pointer up is ignored', () {
      gate.onPointerDown(1);
      gate.onPointerDown(2);
      gate.onPointerUp(9);
      expect(gate.isEnabled, isFalse);
    });
  });
}
