/// Which compiled WebKit content rule lists new webviews attach, and what a
/// sync compiles or drops to get there (content-blocker CB-020).
library;

/// The rule set a group of lists was compiled from: the head of the content
/// blocker's engine inputs key, which changes with the enabled lists, their
/// masks and the app build.
extension type const RuleSetKey._(String raw) {
  factory RuleSetKey.of(String engineInputsKey) {
    assert(
      engineInputsKey.length >= _length,
      'an engine inputs key is a digest',
    );
    return RuleSetKey._(engineInputsKey.substring(0, _length).toLowerCase());
  }

  static const _length = 16;
}

/// A content rule list this app compiled into WebKit's store, named so a
/// later launch finds it without reading the rules:
/// `wcrl-<rule set>-<index>of<count>`.
extension type const RuleListId._(String raw) {
  factory RuleListId.mint({
    required RuleSetKey key,
    required int index,
    required int count,
  }) {
    assert(0 <= index && index < count, 'index names a list of its set');
    return RuleListId._('wcrl-${key.raw}-${index}of$count');
  }

  static final RegExp _shape = RegExp(r'^wcrl-([0-9a-f]{16})-(\d+)of(\d+)$');

  /// Null for an identifier this app did not mint.
  static RuleListId? parse(String raw) =>
      _shape.hasMatch(raw) ? RuleListId._(raw) : null;

  RegExpMatch get _parts => _shape.firstMatch(raw)!;
  RuleSetKey get key => RuleSetKey._(_parts.group(1)!);
  int get index => int.parse(_parts.group(2)!);
  int get count => int.parse(_parts.group(3)!);
}

/// What a sync does. Every case names the lists of ours it leaves in the
/// store unattached, which go once the new set is in place.
sealed class RuleListPlan {
  List<RuleListId> get stale;
}

/// The store holds every list of the wanted set: attach them, in order.
final class AttachStored implements RuleListPlan {
  AttachStored({required this.lists, required this.stale})
    : assert(lists.isNotEmpty, 'a stored set has a list'),
      assert(
        lists.indexed.every((e) => e.$2.index == e.$1),
        'lists are in index order',
      );

  final List<RuleListId> lists;
  @override
  final List<RuleListId> stale;
}

/// The wanted set is missing or incomplete: convert the rules and compile
/// it. [stale] may name ids the compile writes again; those stay.
final class CompileFresh implements RuleListPlan {
  CompileFresh({required this.key, required this.stale});

  final RuleSetKey key;
  @override
  final List<RuleListId> stale;
}

/// No set is wanted: the experiment is off, or no list has rules.
final class AttachNone implements RuleListPlan {
  AttachNone({required this.stale});

  @override
  final List<RuleListId> stale;
}

/// Plans a sync toward [wanted] from the identifiers the store holds.
/// Identifiers this app did not mint are never touched.
RuleListPlan planRuleLists({
  required RuleSetKey? wanted,
  required Iterable<String> stored,
}) {
  final ours = <RuleListId>[for (final raw in stored) ?RuleListId.parse(raw)];
  if (wanted == null) return AttachNone(stale: ours);
  final byCount = <int, Map<int, RuleListId>>{};
  for (final id in ours.where((id) => id.key == wanted)) {
    (byCount[id.count] ??= {})[id.index] = id;
  }
  for (final MapEntry(key: count, value: byIndex) in byCount.entries) {
    if (byIndex.length != count) continue;
    final lists = [for (var i = 0; i < count; i++) byIndex[i]!];
    return AttachStored(
      lists: lists,
      stale: [
        for (final id in ours)
          if (!lists.contains(id)) id,
      ],
    );
  }
  return CompileFresh(key: wanted, stale: ours);
}
