/// How a level of the library, its home or its folders, lays out its items
/// (WEBSPACE-015).
enum LibraryLayout {
  /// Rows while every item fits the room as a row, icons once they would
  /// not, as the drawer packs its sites.
  auto,
  grid,
  list;

  /// The layout [stored] names; [auto] for none, or for one it no longer
  /// knows.
  static LibraryLayout of(String stored) => values.asNameMap()[stored] ?? auto;

  /// Whether [count] items show as rows where [fit] of them fit as rows.
  bool showsRows({required int count, required int fit}) => switch (this) {
    auto => count <= fit,
    grid => false,
    list => true,
  };
}
