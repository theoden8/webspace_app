import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/library_layout.dart';

/// A phone's folder: two columns of rows fit at the narrowest a row may be,
/// its grid holds two icons across, and icons packed three or four across
/// hold three or five a column.
final LibraryRoom _phone = (
  gridColumns: 2,
  rowColumns: 2,
  mostColumns: 4,
  rowsTall: 9,
  iconsTall: (columns) => switch (columns) {
    3 => 3,
    4 => 5,
    _ => 2,
  },
);

/// A wide window's folder: five columns of rows fit at their narrowest, and
/// its grid holds seven icons across.
final LibraryRoom _wide = (
  gridColumns: 7,
  rowColumns: 5,
  mostColumns: 7,
  rowsTall: 10,
  iconsTall: (columns) => 4,
);

LibraryPlacement _auto(int count, {required LibraryRoom room}) =>
    LibraryLayout.auto.place(count: count, room: room);

void main() {
  test('Auto packs a phone\'s folder as the drawer does: one column of rows, '
      'two once they fill it, smaller icons four across once those do, and '
      'only then scrolls (WEBSPACE-015)', () {
    for (final (counts, placement) in [
      ([0, 1, 9], (form: LibraryForm.rows, columns: 1)),
      ([10, 18], (form: LibraryForm.rows, columns: 2)),
      ([19, 20], (form: LibraryForm.icons, columns: 4)),
      ([21, 60], (form: LibraryForm.icons, columns: 4)),
    ]) {
      for (final count in counts) {
        expect(_auto(count, room: _phone), placement, reason: '$count sites');
      }
    }
  });

  test('Auto takes as few columns as hold every item, and rows while a column '
      'is wide enough for one (WEBSPACE-015)', () {
    for (final room in [_phone, _wide]) {
      for (var count = 0; count <= 80; count++) {
        final placed = _auto(count, room: room);
        int holds(LibraryPlacement placement) =>
            placement.columns *
            switch (placement.form) {
              LibraryForm.rows => room.rowsTall,
              LibraryForm.icons => room.iconsTall(placement.columns),
            };
        expect(placed.columns, inInclusiveRange(1, room.mostColumns));
        expect(
          placed.form,
          placed.columns <= room.rowColumns
              ? LibraryForm.rows
              : LibraryForm.icons,
          reason: '$count items in ${placed.columns} columns',
        );
        if (holds(placed) < count) {
          expect(
            placed.columns,
            room.mostColumns,
            reason: 'only the most columns scroll ($count items)',
          );
        }
        for (var fewer = 1; fewer < placed.columns; fewer++) {
          final form = fewer <= room.rowColumns
              ? LibraryForm.rows
              : LibraryForm.icons;
          expect(
            holds((form: form, columns: fewer)),
            lessThan(count),
            reason: '$count items fit $fewer columns',
          );
        }
      }
    }
    expect(_auto(3, room: _wide), (form: LibraryForm.rows, columns: 1));
    expect(_auto(11, room: _wide), (form: LibraryForm.rows, columns: 2));
    expect(_auto(50, room: _wide), (form: LibraryForm.rows, columns: 5));
    expect(_auto(51, room: _wide), (form: LibraryForm.icons, columns: 7));
  });

  test('Grid and List hold whatever the count, and List is one column of '
      'rows however wide the level (WEBSPACE-015)', () {
    for (final count in [0, 4, 40]) {
      expect(
        LibraryLayout.grid.place(count: count, room: _phone),
        (form: LibraryForm.icons, columns: 2),
      );
      for (final room in [_phone, _wide]) {
        expect(
          LibraryLayout.list.place(count: count, room: room),
          (form: LibraryForm.rows, columns: 1),
        );
      }
    }
  });

  test('a stored layout reads back by name, and anything else as Auto', () {
    for (final layout in LibraryLayout.values) {
      expect(LibraryLayout.of(layout.name), layout);
    }
    expect(LibraryLayout.of(''), LibraryLayout.auto);
    expect(LibraryLayout.of('true'), LibraryLayout.auto);
  });
}
