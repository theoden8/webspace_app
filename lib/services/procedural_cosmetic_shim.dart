import 'dart:convert';

import 'package:webspace/services/page_js.dart';

/// The page-side runner for [proceduralActions], the raw JSON strings
/// adblock-rust returns, applied at DOCUMENT_END and on later DOM mutations.
///
/// Returns `null` when no action decodes (the caller skips injection; the
/// runner itself is non-trivial JS). An action of a shape this does not
/// decode is dropped here rather than in the page.
String? buildProceduralCosmeticShim(List<String> proceduralActions) {
  final rules = <Map<String, dynamic>>[];
  for (final raw in proceduralActions) {
    try {
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) rules.add(m);
    } on FormatException {
      // adblock-rust may emit a shape we don't yet handle.
    }
  }
  if (rules.isEmpty) return null;
  return PageJs.proceduralCosmetic.withConfig({'rules': rules});
}
