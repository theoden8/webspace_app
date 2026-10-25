import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/library_layout.dart';

void main() {
  test('Auto shows rows while every item fits as one, as the drawer packs '
      'its sites; Grid and List hold whatever the count (WEBSPACE-015)', () {
    expect(LibraryLayout.auto.showsRows(count: 4, fit: 4), isTrue);
    expect(LibraryLayout.auto.showsRows(count: 5, fit: 4), isFalse);
    expect(LibraryLayout.auto.showsRows(count: 0, fit: 0), isTrue);
    for (final count in [0, 4, 40]) {
      expect(LibraryLayout.grid.showsRows(count: count, fit: 10), isFalse);
      expect(LibraryLayout.list.showsRows(count: count, fit: 10), isTrue);
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
