/// NOTIF-006: while the app is in the foreground, a periodic tick reloads the
/// notification sites, so one that throttles its polling while hidden still
/// checks for new content. The site on screen is left alone: the user is
/// interacting with it.
class ForegroundPollEngine {
  /// [reload] lists the loaded polled sites to reload; [unloaded] counts the
  /// polled ones that have no webview to reload.
  static ({List<int> reload, int unloaded}) plan({
    required int siteCount,
    required int? currentIndex,
    required Set<int> loadedIndices,
    required bool Function(int index) isPolled,
  }) {
    final reload = <int>[];
    var unloaded = 0;
    for (var i = 0; i < siteCount; i++) {
      if (i == currentIndex || !isPolled(i)) continue;
      if (loadedIndices.contains(i)) {
        reload.add(i);
      } else {
        unloaded++;
      }
    }
    return (reload: reload, unloaded: unloaded);
  }
}
