import 'dart:typed_data';

/// Storage abstraction for `WKWebView.interactionState` /
/// `WebView.saveState` bytes, keyed by site ID. Used by the
/// memory-pressure cascade ([SiteLifecyclePromotionEngine]) to persist
/// a webview's navigation state before its renderer is torn down so
/// re-activation can re-hydrate the back/forward stack and (on
/// iOS 15+ / macOS 12+) form-field values via `restoreState`.
///
/// The current default implementation is in-memory only — saved bytes
/// survive webspace switches, LRU evictions, and memory-pressure
/// disposals within a single app run, but are lost on cold start. A
/// future on-disk implementation can drop in here without changes to
/// callers.
///
/// Implementations are expected to be idempotent for both
/// [removeState] and [saveState] (overwrite semantics), and to treat
/// empty / null bytes as "nothing to save" so a webview that never
/// navigated doesn't leave a dangling empty entry that a later
/// `restoreState` would then attempt to apply.
abstract class WebViewStateStorage {
  /// Persist [state] under [siteId]. If [state] is empty, the call
  /// is treated as a no-op (any previously-saved entry is left
  /// untouched).
  Future<void> saveState(String siteId, Uint8List state);

  /// Returns the bytes previously stored for [siteId], or null if
  /// none exist.
  Future<Uint8List?> loadState(String siteId);

  /// Removes any saved bytes for [siteId]. No-op when nothing is
  /// stored.
  Future<void> removeState(String siteId);

  /// Removes every entry whose siteId is not in [activeSiteIds].
  /// Returns the count removed. Run on app startup to reap state
  /// belonging to sites the user deleted in a previous session.
  Future<int> removeOrphans(Set<String> activeSiteIds);

  /// Returns the set of siteIds currently holding state. Used by the
  /// counters in [SiteLifecyclePromotionEngine.tierCounts] and by
  /// debug surfaces.
  Future<Set<String>> siteIds();
}

/// In-memory implementation of [WebViewStateStorage]. State is
/// preserved across webspace switches and memory-pressure disposals
/// within a single app run, and lost on cold start.
class InMemoryWebViewStateStorage implements WebViewStateStorage {
  final Map<String, Uint8List> _store = <String, Uint8List>{};

  @override
  Future<void> saveState(String siteId, Uint8List state) async {
    if (state.isEmpty) return;
    _store[siteId] = state;
  }

  @override
  Future<Uint8List?> loadState(String siteId) async {
    return _store[siteId];
  }

  @override
  Future<void> removeState(String siteId) async {
    _store.remove(siteId);
  }

  @override
  Future<int> removeOrphans(Set<String> activeSiteIds) async {
    var removed = 0;
    final keys = _store.keys.toList();
    for (final k in keys) {
      if (!activeSiteIds.contains(k)) {
        _store.remove(k);
        removed++;
      }
    }
    return removed;
  }

  @override
  Future<Set<String>> siteIds() async {
    return _store.keys.toSet();
  }
}
