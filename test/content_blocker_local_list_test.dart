// Local filter lists (CB-016): rules the user writes in the app rather than
// downloads. Their text is user intent, so it persists with the list entry and
// rides the settings backup, and it must reach the engine like a cached list.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ContentBlockerService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.reset();
    service.store = MemoryFileStore();
  });

  test('a new local list is enabled and its rules reach the rule set',
      () async {
    final id = await service.addLocalList('Mine', '! note\n||ads.local.example^\n');

    final list = service.lists.singleWhere((l) => l.id == id);
    expect(list.isLocal, isTrue);
    expect(list.enabled, isTrue);
    expect(list.lastUpdated, isNotNull);
    expect(list.ruleCount, 1);
    expect(service.abpNetworkBlockHosts, contains('ads.local.example'));
  });

  test('editing replaces the rules in place', () async {
    final id = await service.addLocalList('Mine', '||old.example^');
    await service.updateLocalList(id, 'Renamed', '||new.example^\n||b.example^');

    final list = service.lists.singleWhere((l) => l.id == id);
    expect(list.name, 'Renamed');
    expect(list.ruleCount, 2);
    expect(service.abpNetworkBlockHosts, contains('new.example'));
    expect(service.abpNetworkBlockHosts, isNot(contains('old.example')));
  });

  test('a disabled local list leaves the rule set', () async {
    final id = await service.addLocalList('Mine', '||ads.local.example^');
    await service.toggleList(id, false);

    expect(service.abpNetworkBlockHosts, isNot(contains('ads.local.example')));
  });

  test('a local list is never downloaded', () async {
    final id = await service.addLocalList('Mine', '||ads.local.example^');

    expect(await service.downloadList(id), isFalse);
    expect(await service.downloadAllLists(), 0);
    expect(service.lists.singleWhere((l) => l.id == id).rules,
        '||ads.local.example^');
  });

  test('the rules persist with the list entry across a restart', () async {
    final id = await service.addLocalList('Mine', '||ads.local.example^');
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('content_blocker_lists')!;

    service.reset();
    service.store = MemoryFileStore();
    SharedPreferences.setMockInitialValues({'content_blocker_lists': stored});
    await service.initialize();

    final list = service.lists.singleWhere((l) => l.id == id);
    expect(list.rules, '||ads.local.example^');
    expect(service.abpNetworkBlockHosts, contains('ads.local.example'));
  });

  test('the rules ride the settings backup, download lists stay url-only',
      () async {
    await service.addCustomList('Remote', 'https://x.example/l.txt');
    final id = await service.addLocalList('Mine', '||ads.local.example^');
    final exported = jsonDecode(jsonEncode(service.exportListSelection()))
        as List<dynamic>;

    final remote = exported
        .cast<Map<String, dynamic>>()
        .singleWhere((e) => e['name'] == 'Remote');
    expect(remote.containsKey('rules'), isFalse);

    service.reset();
    service.store = MemoryFileStore();
    await service.importListSelection(exported.cast<Map<String, dynamic>>());

    final list = service.lists.singleWhere((l) => l.id == id);
    expect(list.isLocal, isTrue);
    expect(list.enabled, isTrue);
    expect(list.rules, '||ads.local.example^');
    expect(service.abpNetworkBlockHosts, contains('ads.local.example'));
  });
}
