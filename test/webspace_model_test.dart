import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/webspace_model.dart';
import 'dart:convert';

void main() {
  group('Webspace Model Tests', () {
    test('Create webspace with default values', () {
      final webspace = Webspace(name: 'Test Workspace');

      expect(webspace.name, 'Test Workspace');
      expect(webspace.siteIndices, isEmpty);
      expect(webspace.id, isNotEmpty);
    });

    test('Create webspace with custom ID and site indices', () {
      final webspace = Webspace(
        id: 'custom-id-123',
        name: 'Test Workspace',
        siteIndices: [0, 1, 2],
      );

      expect(webspace.id, 'custom-id-123');
      expect(webspace.name, 'Test Workspace');
      expect(webspace.siteIndices, [0, 1, 2]);
    });

    test('Serialize webspace to JSON', () {
      final webspace = Webspace(
        id: 'test-id',
        name: 'My Workspace',
        siteIndices: [0, 2, 5],
      );

      final json = webspace.toJson();

      expect(json['id'], 'test-id');
      expect(json['name'], 'My Workspace');
      expect(json['siteIndices'], [0, 2, 5]);
    });

    test('Deserialize webspace from JSON', () {
      final json = {
        'id': 'test-id',
        'name': 'My Workspace',
        'siteIndices': [1, 3, 7],
      };

      final webspace = Webspace.fromJson(json);

      expect(webspace.id, 'test-id');
      expect(webspace.name, 'My Workspace');
      expect(webspace.siteIndices, [1, 3, 7]);
    });

    test('JSON round-trip serialization', () {
      final original = Webspace(
        name: 'Test Workspace',
        siteIndices: [0, 1, 2, 3],
      );

      final jsonString = jsonEncode(original.toJson());
      final decoded = Webspace.fromJson(jsonDecode(jsonString));

      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.siteIndices, original.siteIndices);
    });

    test('Empty webspace serialization', () {
      final webspace = Webspace(name: 'Empty Workspace');

      final json = webspace.toJson();
      final restored = Webspace.fromJson(json);

      expect(restored.name, 'Empty Workspace');
      expect(restored.siteIndices, isEmpty);
    });

    test('CopyWith creates new instance with updated fields', () {
      final original = Webspace(
        id: 'original-id',
        name: 'Original',
        siteIndices: [0, 1],
      );

      final updated = original.copyWith(
        name: 'Updated',
        siteIndices: [2, 3, 4],
      );

      expect(updated.id, 'original-id'); // ID should remain the same
      expect(updated.name, 'Updated');
      expect(updated.siteIndices, [2, 3, 4]);
      expect(original.name, 'Original'); // Original should be unchanged
      expect(original.siteIndices, [0, 1]);
    });

    test('CopyWith with partial update', () {
      final original = Webspace(
        name: 'Original',
        siteIndices: [0, 1],
      );

      final updated = original.copyWith(name: 'Updated Name Only');

      expect(updated.name, 'Updated Name Only');
      expect(updated.siteIndices, [0, 1]); // Should keep original
      expect(updated.id, original.id); // Should keep original ID
    });

    test('Handle empty site indices in JSON', () {
      final json = {
        'id': 'test-id',
        'name': 'Test',
        'siteIndices': <int>[],
      };

      final webspace = Webspace.fromJson(json);
      expect(webspace.siteIndices, isEmpty);
    });

    test('Handle large site indices list', () {
      final largeIndicesList = List<int>.generate(100, (i) => i);
      final webspace = Webspace(
        name: 'Large Workspace',
        siteIndices: largeIndicesList,
      );

      final json = webspace.toJson();
      final restored = Webspace.fromJson(json);

      expect(restored.siteIndices.length, 100);
      expect(restored.siteIndices, largeIndicesList);
    });

    test('Multiple webspaces serialization', () {
      final webspaces = [
        Webspace(name: 'Work', siteIndices: [0, 1]),
        Webspace(name: 'Personal', siteIndices: [2, 3, 4]),
        Webspace(name: 'Research', siteIndices: [5]),
      ];

      final jsonList = webspaces.map((ws) => ws.toJson()).toList();
      final jsonString = jsonEncode(jsonList);

      final decodedList = (jsonDecode(jsonString) as List)
          .map((json) => Webspace.fromJson(json))
          .toList();

      expect(decodedList.length, 3);
      expect(decodedList[0].name, 'Work');
      expect(decodedList[1].name, 'Personal');
      expect(decodedList[2].name, 'Research');
      expect(decodedList[0].siteIndices, [0, 1]);
      expect(decodedList[1].siteIndices, [2, 3, 4]);
      expect(decodedList[2].siteIndices, [5]);
    });

    test('Unique IDs for different webspaces', () {
      final webspace1 = Webspace(name: 'Workspace 1');
      final webspace2 = Webspace(name: 'Workspace 2');

      expect(webspace1.id, isNot(webspace2.id));
    });

    test('Special characters in workspace name', () {
      final webspace = Webspace(
        name: 'Test!@#\$%^&*()_+-=[]{}|;:\'",.<>?/`~',
        siteIndices: [0],
      );

      final json = webspace.toJson();
      final restored = Webspace.fromJson(json);

      expect(restored.name, webspace.name);
    });

    test('Unicode characters in workspace name', () {
      final webspace = Webspace(
        name: '工作区 🚀 Espace de travail',
        siteIndices: [0, 1],
      );

      final jsonString = jsonEncode(webspace.toJson());
      final restored = Webspace.fromJson(jsonDecode(jsonString));

      expect(restored.name, '工作区 🚀 Espace de travail');
    });

    test('Duplicate indices in siteIndices', () {
      final webspace = Webspace(
        name: 'Test',
        siteIndices: [0, 1, 1, 2, 2, 2, 3],
      );

      final json = webspace.toJson();
      final restored = Webspace.fromJson(json);

      // Should preserve duplicates as-is (cleanup happens elsewhere)
      expect(restored.siteIndices, [0, 1, 1, 2, 2, 2, 3]);
    });

    test('Negative indices in siteIndices', () {
      final webspace = Webspace(
        name: 'Test',
        siteIndices: [-1, 0, 1],
      );

      final json = webspace.toJson();
      final restored = Webspace.fromJson(json);

      // Should preserve negative indices (cleanup happens elsewhere)
      expect(restored.siteIndices, [-1, 0, 1]);
    });
  });
}
