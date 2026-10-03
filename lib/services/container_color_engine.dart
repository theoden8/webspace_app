/// Which colour each site's container is drawn in (TAB-018).
///
/// A tab runs in exactly one container, the one of the site it runs as, and
/// a tab row says which with that site's colour. Colours are chosen when a
/// site first needs one and then kept, so a site does not change colour when
/// another is added, removed or reordered. Pure: the caller owns the models
/// and persists the result.
library;

abstract final class ContainerColorEngine {
  /// The palette index for each entry of [current] that has none: the least
  /// used index so far, lowest first on a tie, counting every index already
  /// given, including the ones given earlier in the same pass. Entries that
  /// have an index keep it; one outside the palette counts as having none.
  static List<int> assign(List<int?> current, int paletteSize) {
    assert(paletteSize > 0);
    final counts = List<int>.filled(paletteSize, 0);
    bool valid(int? i) => i != null && i >= 0 && i < paletteSize;
    for (final i in current) {
      if (valid(i)) counts[i!]++;
    }
    final out = <int>[];
    for (final i in current) {
      if (valid(i)) {
        out.add(i!);
        continue;
      }
      var best = 0;
      for (var k = 1; k < paletteSize; k++) {
        if (counts[k] < counts[best]) best = k;
      }
      counts[best]++;
      out.add(best);
    }
    return out;
  }

  /// A colour for a site that has none stored, stable for its id. Only for
  /// sites the assignment never sees (an archive's, while it is open): the
  /// app-tier list must not depend on them (ARCH-001).
  static int fallback(String siteId, int paletteSize) {
    var hash = 0x811c9dc5;
    for (final unit in siteId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash % paletteSize;
  }
}
