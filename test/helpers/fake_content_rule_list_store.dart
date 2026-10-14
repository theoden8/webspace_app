import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:webspace/services/content_rule_list_engine.dart';
import 'package:webspace/services/content_rule_lists.dart';

/// [ContentRuleListStore] modelling WebKit's: compiling rejects what is not
/// a JSON array of rules and replaces a list of the same identifier, and
/// removing an identifier the store does not hold is an error, as
/// `removeContentRuleListForIdentifier:` reports one.
class FakeContentRuleListStore implements ContentRuleListStore {
  FakeContentRuleListStore({Iterable<String> stored = const []})
    : lists = {for (final id in stored) id: '[]'};

  /// Identifier to the JSON it was compiled from.
  final Map<String, String> lists;
  final List<String> compiled = [];
  final List<String> removed = [];

  @override
  Future<List<String>> identifiers() async => lists.keys.toList();

  @override
  Future<void> compile(RuleListId id, {required String json}) async {
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.isEmpty) {
      throw PlatformException(
        code: 'compile_failed',
        message: 'not a list of rules',
      );
    }
    lists[id.raw] = json;
    compiled.add(id.raw);
  }

  @override
  Future<void> remove(RuleListId id) async {
    if (lists.remove(id.raw) == null) {
      throw PlatformException(code: 'remove_failed', message: 'no ${id.raw}');
    }
    removed.add(id.raw);
  }
}
