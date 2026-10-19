/// One shard's items, preserving their order. Across all [count] shards,
/// every position in [items] occurs exactly once, even for uneven sizes.
Iterable<T> shardItems<T>(
  List<T> items, {
  required int index,
  required int count,
}) sync* {
  assert(count > 0 && index >= 0 && index < count);
  for (var i = index; i < items.length; i += count) {
    yield items[i];
  }
}
