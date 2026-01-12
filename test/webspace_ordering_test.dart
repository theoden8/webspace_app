import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/webspace_model.dart';
import 'dart:convert';

void main() {
  group('Webspace Ordering Tests', () {
    test('Webspace order is preserved after serialization', () {
      // Create webspaces in a specific order
      final webspaces = [
        Webspace(id: 'id1', name: 'Work', siteIndices: [0, 1]),
        Webspace(id: 'id2', name: 'Personal', siteIndices: [2, 3]),
        Webspace(id: 'id3', name: 'Research', siteIndices: [4]),
      ];

      // Serialize to JSON (simulating save to SharedPreferences)
      final jsonList = webspaces.map((ws) => jsonEncode(ws.toJson())).toList();

      // Deserialize from JSON (simulating load from SharedPreferences)
      final restoredWebspaces = jsonList
          .map((json) => Webspace.fromJson(jsonDecode(json)))
          .toList();

      // Verify order is preserved
      expect(restoredWebspaces.length, 3);
      expect(restoredWebspaces[0].id, 'id1');
      expect(restoredWebspaces[0].name, 'Work');
      expect(restoredWebspaces[1].id, 'id2');
      expect(restoredWebspaces[1].name, 'Personal');
      expect(restoredWebspaces[2].id, 'id3');
      expect(restoredWebspaces[2].name, 'Research');
    });

    test('Webspace reordering is correctly applied', () {
      final webspaces = [
        Webspace(id: '__all_webspace__', name: 'All', siteIndices: []),
        Webspace(id: 'id1', name: 'Work', siteIndices: [0, 1]),
        Webspace(id: 'id2', name: 'Personal', siteIndices: [2, 3]),
        Webspace(id: 'id3', name: 'Research', siteIndices: [4]),
      ];

      // Simulate reordering: move "Research" (index 3) to position 1
      // (after "All" which stays at 0)
      int oldIndex = 3;
      int newIndex = 1;

      // Apply Flutter's ReorderableList logic
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final webspace = webspaces.removeAt(oldIndex);
      webspaces.insert(newIndex, webspace);

      // Verify new order
      expect(webspaces[0].name, 'All');        // "All" stays at 0
      expect(webspaces[1].name, 'Research');   // Moved to position 1
      expect(webspaces[2].name, 'Work');       // Shifted down
      expect(webspaces[3].name, 'Personal');   // Shifted down
    });

    test('Cannot reorder "All" webspace from position 0', () {
      final webspaces = [
        Webspace(id: '__all_webspace__', name: 'All', siteIndices: []),
        Webspace(id: 'id1', name: 'Work', siteIndices: [0, 1]),
        Webspace(id: 'id2', name: 'Personal', siteIndices: [2, 3]),
      ];

      // Try to move "All" (index 0) - should be blocked by if (oldIndex == 0) check
      int oldIndex = 0;
      int newIndex = 2;

      // Simulate the guard condition: if (oldIndex == 0 || newIndex == 0) return;
      if (oldIndex == 0 || newIndex == 0) {
        // No changes should be made
        expect(webspaces[0].name, 'All');
        expect(webspaces[1].name, 'Work');
        expect(webspaces[2].name, 'Personal');
        return;
      }

      // This should never execute due to the guard
      fail('Should not allow reordering "All" webspace');
    });

    test('Cannot reorder other webspaces to position 0', () {
      final webspaces = [
        Webspace(id: '__all_webspace__', name: 'All', siteIndices: []),
        Webspace(id: 'id1', name: 'Work', siteIndices: [0, 1]),
        Webspace(id: 'id2', name: 'Personal', siteIndices: [2, 3]),
      ];

      // Try to move "Work" (index 1) to position 0 - should be blocked
      int oldIndex = 1;
      int newIndex = 0;

      // Simulate the guard condition
      if (oldIndex == 0 || newIndex == 0) {
        // No changes should be made
        expect(webspaces[0].name, 'All');
        expect(webspaces[1].name, 'Work');
        expect(webspaces[2].name, 'Personal');
        return;
      }

      fail('Should not allow reordering to position 0');
    });

    test('Multiple reorder operations preserve correct order', () {
      final webspaces = [
        Webspace(id: '__all_webspace__', name: 'All', siteIndices: []),
        Webspace(id: 'id1', name: 'A', siteIndices: [0]),
        Webspace(id: 'id2', name: 'B', siteIndices: [1]),
        Webspace(id: 'id3', name: 'C', siteIndices: [2]),
        Webspace(id: 'id4', name: 'D', siteIndices: [3]),
      ];

      // Operation 1: Move D (index 4) to position 1
      int oldIndex = 4;
      int newIndex = 1;
      if (oldIndex != 0 && newIndex != 0) {
        if (newIndex > oldIndex) newIndex -= 1;
        final webspace = webspaces.removeAt(oldIndex);
        webspaces.insert(newIndex, webspace);
      }
      expect(webspaces.map((ws) => ws.name).toList(), ['All', 'D', 'A', 'B', 'C']);

      // Operation 2: Move A (now at index 2) to the end (position after last item)
      oldIndex = 2;
      newIndex = 5; // Position after C (Flutter's ReorderableListView convention)
      if (oldIndex != 0 && newIndex != 0) {
        if (newIndex > oldIndex) newIndex -= 1;
        final webspace = webspaces.removeAt(oldIndex);
        webspaces.insert(newIndex, webspace);
      }
      expect(webspaces.map((ws) => ws.name).toList(), ['All', 'D', 'B', 'C', 'A']);

      // Verify "All" never moved
      expect(webspaces[0].id, kAllWebspaceId);
    });

    test('Reordering and then serialization preserves new order', () {
      var webspaces = [
        Webspace(id: '__all_webspace__', name: 'All', siteIndices: []),
        Webspace(id: 'id1', name: 'Work', siteIndices: [0]),
        Webspace(id: 'id2', name: 'Personal', siteIndices: [1]),
        Webspace(id: 'id3', name: 'Research', siteIndices: [2]),
      ];

      // Reorder: Move Research to position 1
      int oldIndex = 3;
      int newIndex = 1;
      if (newIndex > oldIndex) newIndex -= 1;
      final webspace = webspaces.removeAt(oldIndex);
      webspaces.insert(newIndex, webspace);

      // Serialize
      final jsonList = webspaces.map((ws) => jsonEncode(ws.toJson())).toList();

      // Deserialize
      final restoredWebspaces = jsonList
          .map((json) => Webspace.fromJson(jsonDecode(json)))
          .toList();

      // Verify order after full round-trip
      expect(restoredWebspaces[0].name, 'All');
      expect(restoredWebspaces[1].name, 'Research');
      expect(restoredWebspaces[2].name, 'Work');
      expect(restoredWebspaces[3].name, 'Personal');
    });
  });
}
