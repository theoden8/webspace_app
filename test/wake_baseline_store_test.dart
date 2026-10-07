import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/wake_baseline_store.dart';

/// NOTIF-014: a baseline written before the process dies is read back by the
/// next one, and a damaged entry reads as no baseline rather than throwing
/// during startup.
void main() {
  test('round trip', () async {
    SharedPreferences.setMockInitialValues({});
    await WakeBaselineStore.write({'a': 2, 'b': 0});
    expect(await WakeBaselineStore.read(), {'a': 2, 'b': 0});
  });

  test('an empty map removes the entry', () async {
    SharedPreferences.setMockInitialValues({WakeBaselineStore.key: '{"a":1}'});
    await WakeBaselineStore.write({});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(WakeBaselineStore.key), isFalse);
  });

  test('a damaged or wrong-typed entry reads as none', () async {
    for (final bad in <Object>['not json', '[1,2]', true]) {
      SharedPreferences.setMockInitialValues({WakeBaselineStore.key: bad});
      expect(await WakeBaselineStore.read(), isEmpty, reason: '$bad');
    }
    SharedPreferences.setMockInitialValues(
        {WakeBaselineStore.key: '{"a":"3","b":4}'});
    expect(await WakeBaselineStore.read(), {'b': 4});
  });
}
