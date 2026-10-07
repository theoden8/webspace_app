/// A cookie blocked by name + domain, per-site.
/// When a cookie matches, it is deleted from the webview after each page load
/// and skipped during cookie restore.
class BlockedCookie {
  final String name;
  final String domain;

  const BlockedCookie({required this.name, required this.domain});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockedCookie && name == other.name && domain == other.domain;

  @override
  int get hashCode => Object.hash(name, domain);

  Map<String, dynamic> toJson() => {'name': name, 'domain': domain};

  factory BlockedCookie.fromJson(Map<String, dynamic> json) =>
      BlockedCookie(name: json['name'] as String, domain: json['domain'] as String);

  /// Null unless name and domain are both strings.
  static BlockedCookie? tryFromJson(Map<String, dynamic> json) =>
      switch ((json['name'], json['domain'])) {
        (final String name, final String domain) =>
          BlockedCookie(name: name, domain: domain),
        _ => null,
      };
}

/// True if (name, domain) matches one of [blocked]. Domain match is
/// bidirectional-suffix so a block on `example.com` also covers
/// `.a.example.com` and vice versa. Free function so the nested webview
/// screen, which has no model of its own, applies the same rule.
bool matchesBlockedCookie(
  Set<BlockedCookie> blocked,
  String name,
  String? domain,
) {
  if (blocked.isEmpty) return false;
  return blocked.any((b) =>
      b.name == name &&
      (domain != null &&
          (b.domain == domain ||
              domain.endsWith('.${b.domain}') ||
              b.domain.endsWith('.$domain'))));
}
