class ForegroundPollEngine {
  static List<int> indicesToRefresh({
    required int siteCount,
    required int? currentIndex,
    required Set<int> loadedIndices,
    required bool Function(int index) isBackgroundPoll,
  }) {
    final result = <int>[];
    for (int i = 0; i < siteCount; i++) {
      if (i != currentIndex &&
          loadedIndices.contains(i) &&
          isBackgroundPoll(i)) {
        result.add(i);
      }
    }
    return result;
  }
}
