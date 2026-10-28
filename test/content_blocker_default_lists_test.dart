// The lists the app offers on its own (CB-002): a fresh install gets each,
// an install from before a list joined the defaults gets it once, and a
// default the user removed stays removed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/web_intercept_native.dart';

const _all = [
  'easylist',
  'easyprivacy',
  'fanboy-social',
  'fanboy-annoyance',
  'fanboy-cookiemonster',
  'adguard-annoyances',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ContentBlockerService.instance;

  Future<List<String>> launch(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    service.reset();
    service.store = MemoryFileStore();
    await service.initialize(native: WebInterceptNative.initialize());
    return [for (final l in service.lists) l.id];
  }

  Future<Map<String, Object>> stored() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
  }

  String listsJson(List<String> ids) => jsonEncode([
    for (final id in ids)
      {
        'id': id,
        'name': id,
        'url': 'https://lists.example/$id.txt',
        'enabled': true,
      },
  ]);

  test(
    'a fresh install is offered every default, none downloaded, CB-002',
    () async {
      expect(await launch({}), _all);
      expect(service.lists.where((l) => l.lastUpdated != null), isEmpty);
    },
  );

  test(
    'an upgrade from the four defaults gets the new ones once, CB-002',
    () async {
      final ids = await launch({
        'content_blocker_lists': listsJson(_all.take(4).toList()),
      });
      expect(ids, _all);
      expect(
        service.lists.take(4).every((l) => l.enabled),
        isTrue,
        reason: 'what the user had stays as it was',
      );
      expect(
        service.lists.skip(4).any((l) => l.enabled),
        isFalse,
        reason: 'a new default waits for its download',
      );
    },
  );

  test('a default the user removed is not offered again, CB-002', () async {
    await launch({
      'content_blocker_lists': listsJson(['easylist', 'fanboy-social']),
    });
    await service.removeList(
      service.lists.firstWhere((l) => l.id == 'fanboy-cookiemonster').id,
    );
    final after = await stored();

    expect(await launch(after), [
      'easylist',
      'fanboy-social',
      'adguard-annoyances',
    ]);
  });
}
