import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/content_rule_list_engine.dart';
import 'package:webspace/services/content_rule_lists.dart';

import 'helpers/fake_content_rule_list_store.dart';

// Content-blocker CB-020: which compiled WebKit rule lists a webview attaches.

final _a = RuleSetKey.of('aaaaaaaaaaaaaaaa${'0' * 48}');
final _b = RuleSetKey.of('bbbbbbbbbbbbbbbb${'0' * 48}');
final _c = RuleSetKey.of('cccccccccccccccc${'0' * 48}');

String _id(RuleSetKey key, {required int index, required int count}) =>
    RuleListId.mint(key: key, index: index, count: count).raw;

const _rule = '[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]';

void main() {
  group('RuleListId', () {
    test('a minted id parses back to its set, index and count', () {
      final id = RuleListId.parse(_id(_a, index: 1, count: 3))!;
      expect(id.key, _a);
      expect(id.index, 1);
      expect(id.count, 3);
    });

    test('ids this app did not mint do not parse', () {
      expect(RuleListId.parse('ContentBlockingRules'), isNull);
      expect(RuleListId.parse('wcrl-xyz-0of1'), isNull);
    });
  });

  group('planRuleLists', () {
    test('no wanted set drops ours and never touches a foreign list', () {
      final plan = planRuleLists(
        wanted: null,
        stored: [_id(_a, index: 0, count: 1), 'ContentBlockingRules'],
      );
      expect(plan, isA<AttachNone>());
      expect(
        [for (final id in plan.stale) id.raw],
        [_id(_a, index: 0, count: 1)],
      );
    });

    test('a complete stored set attaches in index order', () {
      final plan = planRuleLists(
        wanted: _a,
        stored: [
          _id(_a, index: 1, count: 2),
          _id(_b, index: 0, count: 1),
          _id(_a, index: 0, count: 2),
        ],
      );
      plan as AttachStored;
      expect(
        [for (final id in plan.lists) id.raw],
        [_id(_a, index: 0, count: 2), _id(_a, index: 1, count: 2)],
      );
      expect(
        [for (final id in plan.stale) id.raw],
        [_id(_b, index: 0, count: 1)],
      );
    });

    test('an incomplete set is compiled again', () {
      final plan = planRuleLists(
        wanted: _a,
        stored: [_id(_a, index: 1, count: 2)],
      );
      plan as CompileFresh;
      expect(plan.key, _a);
      expect(plan.interim, isEmpty);
      expect(
        [for (final id in plan.stale) id.raw],
        [_id(_a, index: 1, count: 2)],
      );
    });

    test('a complete earlier set covers the compile, CB-020', () {
      final plan = planRuleLists(
        wanted: _a,
        stored: [
          _id(_c, index: 0, count: 2),
          _id(_b, index: 1, count: 2),
          _id(_b, index: 0, count: 2),
          'ContentBlockingRules',
        ],
      );
      plan as CompileFresh;
      expect(
        [for (final id in plan.interim) id.raw],
        [_id(_b, index: 0, count: 2), _id(_b, index: 1, count: 2)],
        reason: 'only a complete set, in index order',
      );
    });
  });

  group('ContentRuleLists', () {
    late FakeContentRuleListStore store;
    late List<String> converted;

    ContentRuleLists lists({List<String>? Function(String text)? convert}) =>
        ContentRuleLists(
          store: store,
          convert: (text) async {
            converted.add(text);
            return (convert ?? (_) => [_rule, _rule])(text);
          },
        );

    setUp(() {
      converted = [];
      store = FakeContentRuleListStore();
    });

    test(
      'a stored set attaches without reading or converting the rules',
      () async {
        store = FakeContentRuleListStore(stored: [_id(_a, index: 0, count: 1)]);
        final subject = lists();
        await subject.sync(
          wanted: _a,
          rulesText: () => fail('rules read on a warm launch'),
        );
        expect(subject.identifiers, [_id(_a, index: 0, count: 1)]);
        expect(converted, isEmpty);
      },
    );

    test(
      'a missing set compiles once, then attaches and drops the old one, '
      'CB-020',
      () async {
        store = FakeContentRuleListStore(stored: [_id(_b, index: 0, count: 1)]);
        final subject = lists();
        await subject.sync(wanted: _a, rulesText: () async => '||ads^');
        expect(
          subject.identifiers,
          [_id(_b, index: 0, count: 1)],
          reason: 'webviews made during the compile keep the set before',
        );
        await pumpEventQueue();
        expect(converted, ['||ads^']);
        expect(subject.identifiers, [
          _id(_a, index: 0, count: 2),
          _id(_a, index: 1, count: 2),
        ]);
        expect(store.lists.keys, unorderedEquals(subject.identifiers));
      },
    );

    test('a list WebKit refuses leaves no part of the set behind', () async {
      final subject = lists(convert: (_) => [_rule, '{}']);
      await subject.sync(wanted: _a, rulesText: () async => '||ads^');
      await pumpEventQueue();
      expect(subject.identifiers, isEmpty);
      expect(store.lists, isEmpty);
    });

    test('rules that do not convert attach nothing', () async {
      final subject = lists(convert: (_) => null);
      await subject.sync(wanted: _a, rulesText: () async => '||ads^');
      await pumpEventQueue();
      expect(subject.identifiers, isEmpty);
      expect(store.compiled, isEmpty);
    });

    test('a later sync supersedes a compile still running', () async {
      final release = Completer<void>();
      final subject = ContentRuleLists(
        store: store,
        convert: (_) async {
          await release.future;
          return [_rule];
        },
      );
      await subject.sync(wanted: _a, rulesText: () async => '||ads^');
      await subject.sync(wanted: null, rulesText: () async => '');
      release.complete();
      await pumpEventQueue();
      expect(subject.identifiers, isEmpty);
      expect(store.compiled, isEmpty);
    });

    test('the set attached stays until its successor is compiled, CB-020',
        () async {
      store = FakeContentRuleListStore(stored: [_id(_a, index: 0, count: 1)]);
      final release = Completer<void>();
      final subject = ContentRuleLists(
        store: store,
        convert: (_) async {
          await release.future;
          return [_rule];
        },
      );
      await subject.sync(
        wanted: _a,
        rulesText: () => fail('rules read for a stored set'),
      );
      await subject.sync(wanted: _b, rulesText: () async => 'b');
      await pumpEventQueue();
      expect(subject.identifiers, [_id(_a, index: 0, count: 1)]);
      release.complete();
      await pumpEventQueue();
      expect(subject.identifiers, [_id(_b, index: 0, count: 1)]);
      expect(store.lists.keys, [_id(_b, index: 0, count: 1)]);
    });

    test('one compile at a time, and only the newest set waits, CB-020',
        () async {
      final release = Completer<void>();
      final subject = ContentRuleLists(
        store: store,
        convert: (text) async {
          converted.add(text);
          if (text == 'a') await release.future;
          return [_rule];
        },
      );
      await subject.sync(wanted: _a, rulesText: () async => 'a');
      await pumpEventQueue();
      await subject.sync(wanted: _b, rulesText: () async => 'b');
      await subject.sync(wanted: _c, rulesText: () async => 'c');
      await pumpEventQueue();
      expect(converted, ['a'], reason: 'the others wait for the first');
      release.complete();
      await pumpEventQueue();
      expect(converted, ['a', 'c'], reason: 'b was superseded while waiting');
      expect(store.compiled, [_id(_c, index: 0, count: 1)]);
      expect(subject.identifiers, [_id(_c, index: 0, count: 1)]);
    });

    test('turning off drops our lists and keeps foreign ones', () async {
      store = FakeContentRuleListStore(
        stored: [_id(_a, index: 0, count: 1), 'ContentBlockingRules'],
      );
      final subject = lists();
      await subject.sync(wanted: null, rulesText: () async => '');
      expect(subject.identifiers, isEmpty);
      expect(store.lists.keys, ['ContentBlockingRules']);
    });
  });
}
