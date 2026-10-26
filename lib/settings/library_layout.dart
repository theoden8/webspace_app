/// How a level of the library, its home or its folders, lays out its items
/// (WEBSPACE-015).
enum LibraryLayout {
  /// As the drawer packs its sites: as few columns as hold every item
  /// without scrolling, each a row while its column is wide enough for one
  /// and an icon past that; past the most columns, they scroll.
  auto,
  grid,
  list;

  /// The layout [stored] names; [auto] for none, or for one it no longer
  /// knows.
  static LibraryLayout of(String stored) => values.asNameMap()[stored] ?? auto;

  /// Where [count] items go in [room].
  LibraryPlacement place({required int count, required LibraryRoom room}) {
    assert(
      1 <= room.listColumns &&
          room.listColumns <= room.rowColumns &&
          room.rowColumns <= room.mostColumns &&
          room.gridColumns <= room.mostColumns,
      'a level holds at least a column, and List and Grid within its most',
    );
    return switch (this) {
      auto => _packed(count: count, room: room),
      grid => (form: LibraryForm.icons, columns: room.gridColumns),
      list => (form: LibraryForm.rows, columns: room.listColumns),
    };
  }

  static LibraryPlacement _packed({
    required int count,
    required LibraryRoom room,
  }) {
    LibraryPlacement across(int columns) => (
      form: columns <= room.rowColumns ? LibraryForm.rows : LibraryForm.icons,
      columns: columns,
    );
    for (
      var columns = room.listColumns;
      columns < room.mostColumns;
      columns++
    ) {
      final placement = across(columns);
      final tall = switch (placement.form) {
        LibraryForm.rows => room.rowsTall,
        LibraryForm.icons => room.iconsTall(columns),
      };
      if (count <= columns * tall) return placement;
    }
    return across(room.mostColumns);
  }
}

/// What an item of a level shows as: a row, its name beside its icon, or an
/// icon over its name.
enum LibraryForm { rows, icons }

/// So many [columns] across, each item a [form].
typedef LibraryPlacement = ({LibraryForm form, int columns});

/// What a level has room for, as it measures itself: the columns List and
/// Grid lay out in, the most columns of rows its width holds, the most
/// columns Auto takes, and how many items a column holds without scrolling,
/// as rows and as icons so many columns across, which are smaller in
/// narrower columns and so hold more.
typedef LibraryRoom = ({
  int listColumns,
  int gridColumns,
  int rowColumns,
  int mostColumns,
  int rowsTall,
  int Function(int columns) iconsTall,
});
