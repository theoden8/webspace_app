/// How far a blocker's launch read of its data on disk got.
enum BlockerData {
  pending,
  ready,

  /// The data could not be read: the blocker blocks nothing until a
  /// download replaces it, and its rows read as not configured.
  unreadable;

  /// Whether a page may start loading: the read has ended, either way.
  bool get settled => switch (this) {
    pending => false,
    ready || unreadable => true,
  };
}
