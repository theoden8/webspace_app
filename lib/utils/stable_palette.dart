/// A palette slot derived from an identity, stable across launches and ordering.
int stablePaletteIndex(String identity, {required int paletteSize}) {
  assert(paletteSize > 0);
  var hash = 0x811c9dc5;
  for (final unit in identity.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash % paletteSize;
}
