/// Scopes one filter list's rules away from the sites that switched it off.
///
/// The per-site content-blocker mask is carried by the rules themselves,
/// not by the decision path: a masked list's rules get adblock-rust's own
/// domain scoping (`$domain=~host` for network rules, `~host##selector` for
/// cosmetic ones), so the engine answers each site correctly with one copy
/// of the data and no per-request work.
///
/// Rule classification mirrors adblock-rust 0.12's `detect_filter_type`
/// (`lists.rs`) and its option split (the LAST `$` opens the option list,
/// options split on `,`). Diverging from the parser is how a rewrite
/// silently turns a blocking rule into a dropped one.
///
/// Three rule shapes are deliberately left alone, because scoping them would
/// change what they do for every site rather than exempting one:
///
///   * `$badfilter` — it cancels another rule by matching its options, so an
///     added `$domain=` stops the cancellation everywhere.
///   * cosmetic unhide (`#@#` and friends) — adblock-rust rejects a rule
///     that is both an unhide and domain-negated (`DoubleNegation`), so the
///     rewrite would drop the rule outright.
///   * generic scriptlet / procedural / action rules (`##+js(...)`,
///     `##sel:remove()`, `#?#`) — a generic rule with only negated hostnames
///     keeps applying everywhere else *only* for plain hides
///     (`hidden_generic_rule` in `cosmetic_filter_cache_builder.rs`); for
///     these shapes it applies nowhere at all. Generic procedurals also ride
///     the synthetic-host backfill, which is queried once for every site.
library;

import 'dart:convert';

/// uBO/ABP procedural operators. A generic cosmetic rule carrying one of
/// these is not a plain hide, so it is left unscoped — see the library doc.
final RegExp _proceduralPseudo = RegExp(
  r':(?:remove\(|remove-attr\(|remove-class\(|style\(|has-text\(|contains\('
  r'|-abp-contains\(|-abp-has\(|upward\()',
);

/// Rewrite [rulesText] so none of its rules apply on [hosts].
///
/// [hosts] are registrable site hosts; adblock-rust matches a negated domain
/// against the request's source host and its parents, so `example.com`
/// covers `www.example.com` too. Returns [rulesText] unchanged when [hosts]
/// is empty, which is the path every unmasked list takes.
String scopeRulesAwayFromHosts(String rulesText, Iterable<String> hosts) {
  final excluded = <String>[];
  for (final host in hosts) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isNotEmpty) excluded.add(normalized);
  }
  if (excluded.isEmpty) return rulesText;
  excluded.sort();
  final negations = [for (final host in excluded) '~$host'];
  final domainOption = 'domain=${negations.join('|')}';
  final domainSuffix = '|${negations.join('|')}';
  final cosmeticPrefix = negations.join(',');

  final out = StringBuffer();
  for (final line in const LineSplitter().convert(rulesText)) {
    out.writeln(_scopeLine(line, domainOption, domainSuffix, cosmeticPrefix));
  }
  return out.toString();
}

String _scopeLine(
  String line,
  String domainOption,
  String domainSuffix,
  String cosmeticPrefix,
) {
  final filter = line.trim();
  if (filter.isEmpty) return line;
  // detect_filter_type's "not supported" set: comments and list headers.
  if (filter.length == 1 ||
      filter.startsWith('!') ||
      (filter.startsWith('#') && _isWhitespace(filter.codeUnitAt(1))) ||
      filter.startsWith('[Adblock')) {
    return line;
  }
  if (!filter.startsWith('|') && !filter.startsWith('@@|')) {
    final sharp = filter.indexOf('#');
    if (sharp >= 0) {
      final windowEnd = (sharp + 5) < filter.length ? sharp + 5 : filter.length;
      final second = filter.indexOf('#', sharp + 1);
      if (second >= 0 && second < windowEnd) {
        return _scopeCosmetic(filter, sharp, second, cosmeticPrefix);
      }
    }
    // AdGuard HTML filtering rules the crate refuses outright.
    if (filter.contains(r'$$')) return line;
  }
  return _scopeNetwork(filter, domainOption, domainSuffix);
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 || (codeUnit >= 0x09 && codeUnit <= 0x0d);

/// [sharp] is the first `#`, [second] the `#` that closes the separator.
String _scopeCosmetic(
  String filter,
  int sharp,
  int second,
  String cosmeticPrefix,
) {
  final separator = filter.substring(sharp, second + 1);
  if (separator.contains('@')) return filter;
  if (sharp > 0) {
    return '${filter.substring(0, sharp)},$cosmeticPrefix'
        '${filter.substring(sharp)}';
  }
  if (separator != '##') return filter;
  final body = filter.substring(second + 1);
  if (body.startsWith('+js(')) return filter;
  if (_proceduralPseudo.hasMatch(body)) return filter;
  return '$cosmeticPrefix$filter';
}

String _scopeNetwork(String filter, String domainOption, String domainSuffix) {
  // The crate takes the LAST `$` as the option separator, so appending our
  // own would swallow whatever options the rule already carries.
  final dollar = filter.lastIndexOf(r'$');
  if (dollar < 0) return '$filter\$$domainOption';
  final options = filter.substring(dollar + 1).split(',');
  var domainAt = -1;
  for (var i = 0; i < options.length; i++) {
    final option = options[i].trimLeft().toLowerCase();
    if (option == 'badfilter') return filter;
    // `from=` is the crate's alias for `domain=`; a second domain option
    // would replace the first rather than extend it, so merge in place.
    if (domainAt < 0 &&
        (option.startsWith('domain=') || option.startsWith('from='))) {
      domainAt = i;
    }
  }
  if (domainAt < 0) return '$filter,$domainOption';
  options[domainAt] = '${options[domainAt]}$domainSuffix';
  return '${filter.substring(0, dollar + 1)}${options.join(',')}';
}
