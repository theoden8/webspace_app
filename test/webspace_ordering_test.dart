import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/webspace_model.dart';

List<Webspace> _withAll(List<String> names) => [
  Webspace(id: WebspaceId('__all_webspace__'), name: 'All', siteIndices: []),
  for (var i = 0; i < names.length; i++)
    Webspace(id: WebspaceId('id${i + 1}'), name: names[i], siteIndices: [i]),
];

List<String> _names(List<Webspace> webspaces) => [for (final w in webspaces) w.name];

void main() {
  group('Webspace ordering', () {
    test('order is preserved after serialization', () {
      final webspaces = [
        Webspace(id: WebspaceId('id1'), name: 'Work', siteIndices: [0, 1]),
        Webspace(id: WebspaceId('id2'), name: 'Personal', siteIndices: [2, 3]),
        Webspace(id: WebspaceId('id3'), name: 'Research', siteIndices: [4]),
      ];
      final restored = [
        for (final w in webspaces) Webspace.fromJson(jsonDecode(jsonEncode(w.toJson()))),
      ];
      expect([for (final w in restored) w.id], ['id1', 'id2', 'id3']);
      expect(_names(restored), ['Work', 'Personal', 'Research']);
    });

    test('a drop moves the webspace, ReorderableListView style', () {
      final webspaces = _withAll(['Work', 'Personal', 'Research']);
      expect(WebspaceSelectionEngine.reorder(webspaces, from: 3, to: 1), isTrue);
      expect(_names(webspaces), ['All', 'Research', 'Work', 'Personal']);
    });

    test('All stays first: it cannot move, nor be displaced', () {
      final webspaces = _withAll(['Work', 'Personal']);
      expect(WebspaceSelectionEngine.reorder(webspaces, from: 0, to: 2), isFalse);
      expect(WebspaceSelectionEngine.reorder(webspaces, from: 1, to: 0), isFalse);
      expect(_names(webspaces), ['All', 'Work', 'Personal']);
    });

    test('a drop past the dragged item counts the item itself', () {
      final webspaces = _withAll(['A', 'B', 'C', 'D']);
      WebspaceSelectionEngine.reorder(webspaces, from: 4, to: 1);
      expect(_names(webspaces), ['All', 'D', 'A', 'B', 'C']);
      WebspaceSelectionEngine.reorder(webspaces, from: 2, to: 5);
      expect(_names(webspaces), ['All', 'D', 'B', 'C', 'A']);
      expect(webspaces.first.id, WebspaceId.all);
    });

    test('a reordered list serializes in its new order', () {
      final webspaces = _withAll(['Work', 'Personal', 'Research']);
      WebspaceSelectionEngine.reorder(webspaces, from: 3, to: 1);
      final restored = [
        for (final w in webspaces) Webspace.fromJson(jsonDecode(jsonEncode(w.toJson()))),
      ];
      expect(_names(restored), ['All', 'Research', 'Work', 'Personal']);
    });
  });
}
