import 'dart:async';

import 'package:flutter/services.dart';

import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/content_rule_list_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/utils/concurrency.dart';

/// WebKit's store of compiled content rule lists.
abstract interface class ContentRuleListStore {
  /// Every identifier the store holds, ours or not.
  Future<List<String>> identifiers();

  /// Compiles [json], one WebKit rule list, under [id].
  Future<void> compile(RuleListId id, {required String json});

  Future<void> remove(RuleListId id);
}

class MethodChannelContentRuleListStore implements ContentRuleListStore {
  const MethodChannelContentRuleListStore._(this._channel);

  /// The store this host's webviews attach from, or null where WebKit has
  /// none. On iOS and macOS the Runner's `ContentRuleListPlugin` compiles into
  /// `WKContentRuleListStore.default()`. WPE has no default store, so on Linux
  /// it is the webview plugin's own, the one its webviews read.
  static MethodChannelContentRuleListStore? get here => hostIsLinux
      ? const MethodChannelContentRuleListStore._(
          MethodChannel(
            'com.pichillilorenzo/flutter_inappwebview_content_rule_list_store',
          ),
        )
      : hostIsIOS || hostIsMacOS
      ? const MethodChannelContentRuleListStore._(
          MethodChannel('org.codeberg.theoden8.webspace/content_rule_lists'),
        )
      : null;

  final MethodChannel _channel;

  @override
  Future<List<String>> identifiers() async =>
      (await _channel.invokeListMethod<String>('identifiers')) ?? const [];

  @override
  Future<void> compile(RuleListId id, {required String json}) => _channel
      .invokeMethod<void>('compile', {'identifier': id.raw, 'json': json});

  @override
  Future<void> remove(RuleListId id) =>
      _channel.invokeMethod<void>('remove', {'identifier': id.raw});
}

/// Owns which compiled WebKit content rule lists new webviews attach on
/// iOS, macOS and Linux (content-blocker CB-020). A set is compiled once per
/// rule set and found again by name on later launches; a webview only names
/// it.
class ContentRuleLists {
  ContentRuleLists({required this.store, required this.convert});

  final ContentRuleListStore store;

  /// Rules text to WebKit rule lists, one JSON array each; null on failure.
  final Future<List<String>?> Function(String rulesText) convert;

  List<RuleListId> _attached = const [];
  int _generation = 0;

  /// One compile at a time: WebKit parses a list on the main thread as its
  /// compile starts (half a second for the default lists on WPE), so a burst
  /// of changes compiles the set running and then only the newest.
  final SerialQueue _compiles = SerialQueue('contentRuleListCompiles');

  /// The lists a webview created now attaches.
  List<String> get identifiers => [for (final id in _attached) id.raw];

  /// Points new webviews at the set for [wanted], or at none when null.
  /// Returns once the store has been read; a set that has to be compiled is
  /// compiled after, and attaches when it is done, new webviews keeping the
  /// set before until then. A later call supersedes one still compiling or
  /// waiting to.
  Future<void> sync({
    required RuleSetKey? wanted,
    required Future<String> Function() rulesText,
  }) async {
    final generation = ++_generation;
    final List<String> stored;
    try {
      stored = await store.identifiers();
    } on PlatformException catch (e) {
      LogTag.contentBlocker.warning('Content rule lists unreadable: $e');
      _attached = const [];
      return;
    } on MissingPluginException {
      _attached = const [];
      return;
    }
    if (generation != _generation) return;
    switch (planRuleLists(wanted: wanted, stored: stored)) {
      case AttachStored(:final lists, :final stale):
        _attached = lists;
        LogTag.contentBlocker.info(
          'Content rule lists attached from the store: ${lists.length}',
        );
        await _removeAll(stale);
      case AttachNone(:final stale):
        _attached = const [];
        await _removeAll(stale);
      case CompileFresh(:final key, :final interim, :final stale):
        if (_attached.isEmpty) _attached = interim;
        _compiles.enqueue(
          () => _compile(
            key: key,
            stale: stale,
            rulesText: rulesText,
            generation: generation,
          ),
        );
    }
  }

  @Held(#_compiles)
  Future<void> _compile({
    required RuleSetKey key,
    required List<RuleListId> stale,
    required Future<String> Function() rulesText,
    required int generation,
  }) async {
    if (generation != _generation) return;
    final sw = Stopwatch()..start();
    final lists = await convert(await rulesText());
    if (generation != _generation) return;
    if (lists == null) {
      LogTag.contentBlocker.warning(
        'Content rule lists not built: the rules did not convert',
      );
      return;
    }
    final ids = [
      for (var i = 0; i < lists.length; i++)
        RuleListId.mint(key: key, index: i, count: lists.length),
    ];
    for (var i = 0; i < lists.length; i++) {
      try {
        await store.compile(ids[i], json: lists[i]);
      } on PlatformException catch (e) {
        LogTag.contentBlocker.warning(
          'Content rule list ${ids[i].raw} did not compile: $e',
        );
        await _removeAll(ids.take(i));
        return;
      }
      if (generation != _generation) return;
    }
    _attached = ids;
    LogTag.contentBlocker.info(
      'Content rule lists compiled: ${ids.length} '
      '(${lists.fold<int>(0, (n, l) => n + l.length)} bytes, '
      '${sw.elapsedMilliseconds}ms)',
    );
    await _removeAll(stale.where((id) => !ids.contains(id)));
  }

  Future<void> _removeAll(Iterable<RuleListId> ids) async {
    for (final id in ids) {
      try {
        await store.remove(id);
      } on PlatformException catch (e) {
        LogTag.contentBlocker.warning(
          'Content rule list ${id.raw} not removed: $e',
        );
      }
    }
  }
}
