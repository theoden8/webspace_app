import 'dart:convert';

/// The domain a blocklist [line] names: the line itself in a domain list, its
/// last field in a hosts file; null for a blank line or a comment.
String? listedDomain(String line) {
  final hash = line.indexOf('#');
  final text = (hash < 0 ? line : line.substring(0, hash)).trim();
  if (text.isEmpty) return null;
  final space = text.lastIndexOf(RegExp(r'\s'));
  return (space < 0 ? text : text.substring(space + 1)).toLowerCase();
}

/// The domains [list] names, a line at a time.
Iterable<String> listedDomains(String list) sync* {
  for (final line in LineSplitter.split(list)) {
    final domain = listedDomain(line);
    if (domain != null) yield domain;
  }
}
