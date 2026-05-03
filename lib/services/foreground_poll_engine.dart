class ForegroundPollEngine {
  static List<int> indicesToRefresh({
    required int siteCount,
    required int? currentIndex,
    required Set<int> loadedIndices,
    required bool Function(int index) isPolled,
  }) {
    final result = <int>[];
    for (int i = 0; i < siteCount; i++) {
      if (i != currentIndex &&
          loadedIndices.contains(i) &&
          isPolled(i)) {
        result.add(i);
      }
    }
    return result;
  }
}
