import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/webspace_model.dart';

void main() {
  group('Webspace model', () {
    test('default-constructed webspace has empty siteIds and siteIndices', () {
      final webspace = Webspace(name: 'Test Workspace');
      expect(webspace.name, 'Test Workspace');
      expect(webspace.siteIds, isEmpty);
      expect(webspace.siteIndices, isEmpty);
      expect(webspace.id, isNotEmpty);
    });

    test('constructor accepts explicit id, siteIds, and siteIndices', () {
      final webspace = Webspace(
        id: 'custom-id-123',
        name: 'Test Workspace',
        siteIds: ['s0', 's1', 's2'],
        siteIndices: [0, 1, 2],
      );
      expect(webspace.id, 'custom-id-123');
      expect(webspace.siteIds, ['s0', 's1', 's2']);
      expect(webspace.siteIndices, [0, 1, 2]);
    });

    test('toJson persists siteIds, not siteIndices', () {
      final webspace = Webspace(
        id: 'test-id',
        name: 'My Workspace',
        siteIds: ['siteA', 'siteB', 'siteC'],
        siteIndices: [0, 2, 5],
      );
      final json = webspace.toJson();
      expect(json['id'], 'test-id');
      expect(json['name'], 'My Workspace');
      expect(json['siteIds'], ['siteA', 'siteB', 'siteC']);
      // Runtime-only field — never serialised.
      expect(json.containsKey('siteIndices'), isFalse);
    });

    test('fromJson reads new siteIds form', () {
      final webspace = Webspace.fromJson({
        'id': 'test-id',
        'name': 'My Workspace',
        'siteIds': ['siteA', 'siteB', 'siteC'],
      });
      expect(webspace.id, 'test-id');
      expect(webspace.siteIds, ['siteA', 'siteB', 'siteC']);
      expect(webspace.siteIndices, isEmpty);
    });

    test('fromJson migrates legacy siteIndices into the runtime view', () {
      // Older builds persisted positional `siteIndices`. fromJson keeps
      // them in the runtime field so the resolver in `_WebSpacePageState`
      // can translate to siteIds on next load.
      final webspace = Webspace.fromJson({
        'id': 'legacy-id',
        'name': 'Legacy',
        'siteIndices': [1, 3, 7],
      });
      expect(webspace.id, 'legacy-id');
      expect(webspace.siteIds, isEmpty);
      expect(webspace.siteIndices, [1, 3, 7]);
    });

    test('JSON round-trip preserves siteIds', () {
      final original = Webspace(
        name: 'Test Workspace',
        siteIds: ['a', 'b', 'c', 'd'],
      );
      final decoded = Webspace.fromJson(jsonDecode(jsonEncode(original.toJson())));
      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.siteIds, original.siteIds);
    });

    test('Empty webspace round-trips', () {
      final webspace = Webspace(name: 'Empty Workspace');
      final restored = Webspace.fromJson(webspace.toJson());
      expect(restored.name, 'Empty Workspace');
      expect(restored.siteIds, isEmpty);
      expect(restored.siteIndices, isEmpty);
    });

    test('copyWith updates fields without aliasing the source lists', () {
      final original = Webspace(
        id: 'original-id',
        name: 'Original',
        siteIds: ['a', 'b'],
        siteIndices: [0, 1],
      );
      final updated = original.copyWith(
        name: 'Updated',
        siteIds: ['c', 'd', 'e'],
        siteIndices: [2, 3, 4],
      );
      expect(updated.id, 'original-id');
      expect(updated.name, 'Updated');
      expect(updated.siteIds, ['c', 'd', 'e']);
      expect(updated.siteIndices, [2, 3, 4]);
      expect(original.name, 'Original');
      expect(original.siteIds, ['a', 'b']);
    });

    test('copyWith with partial update keeps untouched fields', () {
      final original = Webspace(
        name: 'Original',
        siteIds: ['a', 'b'],
      );
      final updated = original.copyWith(name: 'Updated Name Only');
      expect(updated.name, 'Updated Name Only');
      expect(updated.siteIds, ['a', 'b']);
      expect(updated.id, original.id);
    });

    test('Unique IDs for default-constructed webspaces', () {
      final a = Webspace(name: 'Workspace 1');
      final b = Webspace(name: 'Workspace 2');
      expect(a.id, isNot(b.id));
    });

    test('special characters in name round-trip', () {
      final webspace = Webspace(
        name: 'Test!@#\$%^&*()_+-=[]{}|;:\'",.<>?/`~',
        siteIds: ['s0'],
      );
      final restored = Webspace.fromJson(webspace.toJson());
      expect(restored.name, webspace.name);
    });

    test('unicode in name round-trips through JSON', () {
      final webspace = Webspace(
        name: '工作区 🚀 Espace de travail',
        siteIds: ['s0', 's1'],
      );
      final restored = Webspace.fromJson(jsonDecode(jsonEncode(webspace.toJson())));
      expect(restored.name, webspace.name);
    });

    test('large siteIds list round-trips', () {
      final large = List<String>.generate(100, (i) => 'site-$i');
      final webspace = Webspace(name: 'Large Workspace', siteIds: large);
      final restored = Webspace.fromJson(webspace.toJson());
      expect(restored.siteIds.length, 100);
      expect(restored.siteIds, large);
    });

    test('Webspace.all yields the synthetic All webspace', () {
      final all = Webspace.all();
      expect(all.id, kAllWebspaceId);
      expect(all.isAll, isTrue);
      expect(all.siteIds, isEmpty);
    });

    // Defensive deserialization: malformed prefs blobs from partial
    // writes, hand-edited backups, or schema drift across branches
    // must not crash boot. `_loadWebspaces` wraps each entry in
    // try/catch, but each field also defends individually so the
    // entry is at worst empty rather than dropped wholesale.
    group('fromJson tolerates missing/null fields', () {
      test('missing siteIds and siteIndices both default to empty', () {
        final webspace = Webspace.fromJson({'id': 'x', 'name': 'NoMembership'});
        expect(webspace.id, 'x');
        expect(webspace.name, 'NoMembership');
        expect(webspace.siteIds, isEmpty);
        expect(webspace.siteIndices, isEmpty);
      });

      test('null siteIds defaults to empty', () {
        final webspace = Webspace.fromJson({
          'id': 'x',
          'name': 'NullIds',
          'siteIds': null,
        });
        expect(webspace.siteIds, isEmpty);
      });

      test('null siteIndices (legacy form) defaults to empty', () {
        final webspace = Webspace.fromJson({
          'id': 'x',
          'name': 'NullLegacy',
          'siteIndices': null,
        });
        expect(webspace.siteIndices, isEmpty);
        expect(webspace.siteIds, isEmpty);
      });

      test('missing id generates a fresh one', () {
        final webspace = Webspace.fromJson({'name': 'NoId', 'siteIds': ['a']});
        expect(webspace.id, isNotEmpty);
      });

      test('missing name defaults to Untitled', () {
        final webspace = Webspace.fromJson({'id': 'x', 'siteIds': []});
        expect(webspace.name, 'Untitled');
      });

      test('empty map yields a usable, non-crashing Webspace', () {
        final webspace = Webspace.fromJson(<String, dynamic>{});
        expect(webspace.id, isNotEmpty);
        expect(webspace.name, 'Untitled');
        expect(webspace.siteIds, isEmpty);
        expect(webspace.siteIndices, isEmpty);
      });

      test('mixed-type entries in siteIds are filtered to strings', () {
        final webspace = Webspace.fromJson({
          'id': 'x',
          'name': 'Mixed',
          'siteIds': ['a', 42, null, 'b'],
        });
        expect(webspace.siteIds, ['a', 'b']);
      });

      test('mixed-type entries in legacy siteIndices are filtered to ints', () {
        final webspace = Webspace.fromJson({
          'id': 'x',
          'name': 'Mixed',
          'siteIndices': [0, '1', null, 2],
        });
        expect(webspace.siteIndices, [0, 2]);
      });
    });

    // Cross-branch schema migration: pin every historical persisted
    // shape so a future schema change has to update the snapshot,
    // forcing whoever touches the model to think about migration.
    // Without this, a one-way schema change silently breaks the
    // downgrade-then-upgrade path (the root cause of the original
    // null-cast crash: see lib/webspace_model.dart history).
    group('historical schema snapshots load without loss', () {
      test('v1: {id,name,siteIndices} (master pre-siteIds) loads as legacy', () {
        const raw =
            '{"id":"ws-old","name":"Legacy Master","siteIndices":[0,2,5]}';
        final webspace = Webspace.fromJson(jsonDecode(raw));
        expect(webspace.id, 'ws-old');
        expect(webspace.name, 'Legacy Master');
        expect(webspace.siteIds, isEmpty,
            reason: 'siteIds gets populated by _migrateLegacyWebspaceIndices '
                'after _webViewModels loads');
        expect(webspace.siteIndices, [0, 2, 5]);
      });

      test('v2: {id,name,siteIds} (new schema) loads cleanly', () {
        const raw =
            '{"id":"ws-new","name":"New Schema","siteIds":["a","b","c"]}';
        final webspace = Webspace.fromJson(jsonDecode(raw));
        expect(webspace.id, 'ws-new');
        expect(webspace.name, 'New Schema');
        expect(webspace.siteIds, ['a', 'b', 'c']);
        expect(webspace.siteIndices, isEmpty);
      });

      test('mixed: both keys present prefers siteIds, keeps legacy for resolver', () {
        // A round-trip through a branch that wrote both fields. We
        // honour siteIds (the source of truth) and keep siteIndices
        // around so the resolver can still produce the runtime view.
        const raw =
            '{"id":"ws","name":"Both","siteIds":["a","b"],"siteIndices":[0,1]}';
        final webspace = Webspace.fromJson(jsonDecode(raw));
        expect(webspace.siteIds, ['a', 'b']);
        expect(webspace.siteIndices, [0, 1]);
      });
    });
  });
}
